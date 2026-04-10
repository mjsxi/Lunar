//
//  PythonMLXBackend.swift
//  Lunar
//
//  macOS-only backend that runs Apple's `mlx_lm.server` as a subprocess and
//  talks to it over its OpenAI-compatible HTTP API. The user must have a
//  Python install with `mlx-lm` available; the python path is configured in
//  Settings → Python Backend (defaults to `/usr/bin/env python3`).
//
//  NOTE: spawning a subprocess requires the macOS target to NOT be sandboxed.
//

#if os(macOS)
import Foundation

final class PythonMLXBackend: InferenceBackend {
    private(set) var serverProcess: Process?
    private(set) var serverPort: Int?
    private var loadedModelName: String?
    private var currentTask: URLSessionDataTask?
    private var cancelled = false

    private var pythonPath: String {
        UserDefaults.standard.string(forKey: "pythonExecutablePath") ?? "/usr/bin/env"
    }
    private var pythonArgsPrefix: [String] {
        let stored = UserDefaults.standard.string(forKey: "pythonExecutablePath")
        // If user gave a direct path (e.g. /opt/homebrew/bin/python3), no prefix.
        // Otherwise default to `env python3`.
        if stored == nil { return ["python3"] }
        return []
    }

    /// Last error output captured from the Python server's stderr.
    private(set) var lastServerError: String?

    func load(modelName: String, progress: @escaping (Double) -> Void) async throws {
        if loadedModelName == modelName, serverProcess?.isRunning == true { return }
        await stopServer()
        lastServerError = nil

        let port = Int.random(in: 49152...65535)

        // Read per-model Python backend settings from UserDefaults.
        let prefillStepSize: Int = {
            if let data = UserDefaults.standard.data(forKey: "modelPrefillStepSize"),
               let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
                return dict[modelName] ?? 8192
            }
            return 8192
        }()
        let cacheGB: Int = {
            if let data = UserDefaults.standard.data(forKey: "modelPromptCacheGB"),
               let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
                return dict[modelName] ?? 8
            }
            return 8
        }()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = pythonArgsPrefix + [
            "-m", "mlx_lm.server",
            "--model", modelName,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--prefill-step-size", "\(prefillStepSize)",
            "--prompt-cache-bytes", "\(cacheGB)GB"
        ]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        try proc.run()
        serverProcess = proc
        serverPort = port
        loadedModelName = modelName

        // Poll until the server answers /v1/models or fails.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if !proc.isRunning {
                let errData = errPipe.fileHandleForReading.availableData
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = errText.flatMap { text in
                    text.split(separator: "\n", omittingEmptySubsequences: true)
                        .suffix(3)
                        .joined(separator: "\n")
                }
                lastServerError = tail
                let message = tail ?? "mlx_lm.server exited before becoming ready"
                throw NSError(domain: "PythonMLXBackend", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            if (try? await ping(port: port)) == true {
                progress(1.0)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            progress(0.5)
        }
        proc.terminate()
        lastServerError = "Timed out waiting for mlx_lm.server (120s)"
        throw NSError(domain: "PythonMLXBackend", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for mlx_lm.server"])
    }

    private func ping(port: Int) async throws -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        req.timeoutInterval = 1
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func generate(modelName: String,
                  messages: [ChatTurn],
                  params: GenerateParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.load(modelName: modelName) { _ in }
                    guard let port = self.serverPort else {
                        continuation.finish(throwing: NSError(domain: "PythonMLXBackend", code: 3))
                        return
                    }
                    self.cancelled = false

                    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": modelName,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "temperature": params.temperature,
                        "top_p": params.topP,
                        "top_k": params.topK,
                        "max_tokens": params.maxTokens,
                        "stop": ["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<|end|>"],
                        "stream": true
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    var accumulated = ""
                    for try await line in bytes.lines {
                        if self.cancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let chunk = delta["content"] as? String {
                            accumulated += chunk
                            continuation.yield(accumulated)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        currentTask?.cancel()
    }

    func stopServer() async {
        if let p = serverProcess, p.isRunning {
            p.terminate()
        }
        serverProcess = nil
        serverPort = nil
        loadedModelName = nil
    }

    // MARK: - Auto-probe / install helpers

    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/python3",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/usr/local/bin/python3",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.11",
        "/usr/bin/python3",
    ]

    /// Walks `candidatePaths` and returns the first python that can `import mlx_lm`.
    /// Falls back to the first python that exists if none have mlx-lm. Caches the
    /// winning path in UserDefaults("pythonExecutablePath") so subsequent backend
    /// spawns reuse it without re-probing.
    static func probe() async -> PythonProbeStatus {
        var firstFoundPython: String? = nil
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            if firstFoundPython == nil { firstFoundPython = path }
            if let version = await runImportCheck(path: path) {
                UserDefaults.standard.set(path, forKey: "pythonExecutablePath")
                return .ready(path: path, mlxVersion: version)
            }
        }
        if let path = firstFoundPython {
            UserDefaults.standard.set(path, forKey: "pythonExecutablePath")
            return .missingMLXLM(path: path)
        }
        UserDefaults.standard.removeObject(forKey: "pythonExecutablePath")
        return .noPython
    }

    /// Runs `<path> -c "import mlx_lm; print(mlx_lm.__version__)"` and returns
    /// the version string if it succeeds, otherwise nil.
    private static func runImportCheck(path: String) async -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-c", "import mlx_lm; print(mlx_lm.__version__)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return proc.terminationStatus == 0 ? out : nil
        } catch {
            return nil
        }
    }

    /// Tries `python -m pip install --user --upgrade mlx-lm`. Captures combined stdout/stderr.
    /// Works for both initial install and updates.
    static func installMLXLM(using pythonPath: String) async -> PipInstallResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-m", "pip", "install", "--user", "--upgrade", "mlx-lm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            let lastLine = out
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .last?
                .trimmingCharacters(in: .whitespaces)
            return PipInstallResult(success: proc.terminationStatus == 0, stderrTail: lastLine)
        } catch {
            return PipInstallResult(success: false, stderrTail: error.localizedDescription)
        }
    }
}

extension PythonMLXBackend {
    /// Minimum supported Python version for mlx-lm.
    static let minimumPythonVersion: (Int, Int) = (3, 10)

    /// Runs `<path> --version` and parses "Python 3.12.4" → "3.12.4".
    static func pythonVersion(at path: String) async -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // "Python 3.12.4"
            return raw.split(separator: " ").last.map(String.init)
        } catch {
            return nil
        }
    }

    /// True if the installed Python is older than `minimumPythonVersion`.
    static func isPythonOutdated(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        let (major, minor) = (parts[0], parts[1])
        if major < minimumPythonVersion.0 { return true }
        if major == minimumPythonVersion.0 && minor < minimumPythonVersion.1 { return true }
        return false
    }

    /// Queries PyPI for the latest published mlx-lm version.
    static func fetchLatestMLXLMVersion() async -> String? {
        guard let url = URL(string: "https://pypi.org/pypi/mlx-lm/json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = obj["info"] as? [String: Any],
                  let version = info["version"] as? String else { return nil }
            return version
        } catch {
            return nil
        }
    }

    /// Returns true if `latest` is strictly newer than `installed` using
    /// numeric component compare (e.g. "0.20.5" vs "0.21.0").
    static func isNewerVersion(_ latest: String, than installed: String) -> Bool {
        let l = latest.split(separator: ".").map { Int($0) ?? 0 }
        let i = installed.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(l.count, i.count)
        for idx in 0..<count {
            let a = idx < l.count ? l[idx] : 0
            let b = idx < i.count ? i[idx] : 0
            if a != b { return a > b }
        }
        return false
    }
}

enum PythonProbeStatus: Equatable {
    case ready(path: String, mlxVersion: String)
    case missingMLXLM(path: String)
    case noPython
}

struct PipInstallResult {
    let success: Bool
    let stderrTail: String?
}
#endif
