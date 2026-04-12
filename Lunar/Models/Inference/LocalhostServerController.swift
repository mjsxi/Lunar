import Foundation
import SwiftUI

#if os(macOS)
import Network
#endif

@MainActor
final class LocalhostServerController: ObservableObject {
    @Published private(set) var state: State = .idle
    @Published private(set) var pinnedModelName: String?
    @Published private(set) var pinnedBackend: BackendKind?

    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    private let appPreferences: AppPreferences
    private let modelSettings: ModelSettingsStore
    private let llm: LLMEvaluator
    private let generationGate = LocalhostGenerationGate()

    #if os(macOS)
    private var server: LocalhostHTTPServer?
    #endif

    init(appPreferences: AppPreferences, modelSettings: ModelSettingsStore, llm: LLMEvaluator) {
        self.appPreferences = appPreferences
        self.modelSettings = modelSettings
        self.llm = llm
    }

    var configuredPort: Int {
        appPreferences.localhostServerPort
    }

    var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var isEnabled: Bool {
        appPreferences.localhostServerEnabled
    }

    var isLocked: Bool {
        isEnabled || state == .starting || state == .running
    }

    var endpointURLString: String {
        "http://127.0.0.1:\(configuredPort)"
    }

    var statusText: String {
        switch state {
        case .idle:
            return "off"
        case .starting:
            return "starting…"
        case .running:
            return "running on \(endpointURLString)"
        case .failed(let message):
            return message
        }
    }

    func updateConfiguredPort(_ port: Int) {
        appPreferences.localhostServerPort = port
    }

    func restoreIfNeeded() async {
        guard appPreferences.localhostServerEnabled else { return }
        await setEnabled(true, restoring: true)
    }

    func setEnabled(_ enabled: Bool) async {
        await setEnabled(enabled, restoring: false)
    }

    private func setEnabled(_ enabled: Bool, restoring: Bool) async {
        if enabled {
            await start(restoring: restoring)
        } else {
            await stop()
        }
    }

    private func start(restoring: Bool) async {
        guard isSupported else {
            state = .failed("localhost serving is only available on macOS")
            appPreferences.localhostServerEnabled = false
            return
        }
        guard state != .starting, state != .running else { return }
        guard !llm.running else {
            state = .failed("finish the current chat response before enabling localhost")
            appPreferences.localhostServerEnabled = false
            return
        }
        guard let modelName = appPreferences.currentModelName, !modelName.isEmpty else {
            state = .failed("select a model before enabling localhost")
            appPreferences.localhostServerEnabled = false
            return
        }
        guard (1...65_535).contains(configuredPort) else {
            state = .failed("localhost port must be between 1 and 65535")
            appPreferences.localhostServerEnabled = false
            return
        }

        let backend = modelSettings.backend(for: modelName)
        pinnedModelName = modelName
        pinnedBackend = backend
        appPreferences.localhostServerEnabled = true
        state = .starting

        #if os(macOS)
        do {
            let configuredPort = self.configuredPort
            let server = LocalhostHTTPServer(port: configuredPort) { [weak self] request in
                guard let self else {
                    return Self.errorResponse(status: 500, message: "localhost server unavailable", type: "server_error")
                }
                return await self.handle(request: request)
            }
            try await server.start()
            self.server = server
            state = .running
            AppLogger.localhost.info("localhost serving enabled model=\(modelName, privacy: .public) backend=\(backend.rawValue, privacy: .public) port=\(configuredPort, privacy: .public)")
        } catch {
            let message = "couldn't bind \(endpointURLString): \(error.localizedDescription)"
            state = .failed(message)
            appPreferences.localhostServerEnabled = false
            pinnedModelName = nil
            pinnedBackend = nil
            AppLogger.localhost.error("localhost serving failed to start on port \(self.configuredPort, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        #else
        if !restoring {
            state = .failed("localhost serving is only available on macOS")
        }
        appPreferences.localhostServerEnabled = false
        pinnedModelName = nil
        pinnedBackend = nil
        #endif
    }

    func stop() async {
        #if os(macOS)
        server?.stop()
        server = nil
        #endif
        appPreferences.localhostServerEnabled = false
        pinnedModelName = nil
        pinnedBackend = nil
        state = .idle
        AppLogger.localhost.info("localhost serving disabled")
    }

    #if os(macOS)
    fileprivate func handle(request: LocalhostHTTPRequest) async -> LocalhostHTTPResponse {
        guard case .running = state else {
            return Self.errorResponse(status: 503, message: "localhost serving is not active", type: "server_unavailable")
        }

        switch (request.method.uppercased(), request.path) {
        case ("GET", "/v1/models"):
            return modelsResponse()
        case ("POST", "/v1/chat/completions"):
            return await chatCompletionsResponse(for: request)
        default:
            return Self.errorResponse(status: 404, message: "endpoint not found", type: "not_found_error")
        }
    }

    private func modelsResponse() -> LocalhostHTTPResponse {
        let model = pinnedModelName ?? appPreferences.currentModelName ?? "unknown"
        let payload = OpenAIModelsResponse(
            data: [
                OpenAIModelDescriptor(
                    id: model,
                    created: Int(Date().timeIntervalSince1970),
                    owned_by: "lunar"
                )
            ]
        )
        return Self.jsonResponse(status: 200, payload: payload)
    }

    private func chatCompletionsResponse(for request: LocalhostHTTPRequest) async -> LocalhostHTTPResponse {
        guard let modelName = pinnedModelName, let backend = pinnedBackend else {
            return Self.errorResponse(status: 503, message: "localhost serving is not pinned to a model", type: "server_unavailable")
        }
        guard await generationGate.acquire() else {
            return Self.errorResponse(status: 409, message: "localhost server is busy with another request", type: "server_busy")
        }

        let decoder = JSONDecoder()
        let chatRequest: OpenAIChatCompletionRequest
        do {
            chatRequest = try decoder.decode(OpenAIChatCompletionRequest.self, from: request.body)
        } catch {
            await generationGate.release()
            return Self.errorResponse(status: 400, message: "invalid JSON request body", type: "invalid_request_error")
        }

        if let requestedModel = chatRequest.model, requestedModel != modelName {
            await generationGate.release()
            return Self.errorResponse(
                status: 400,
                message: "localhost is pinned to \(modelName); requested \(requestedModel)",
                type: "invalid_request_error"
            )
        }

        let messages = chatRequest.messages.map {
            ChatTurn(role: $0.role, content: $0.content.flattenedText)
        }
        let params = GenerateParams(
            temperature: chatRequest.temperature ?? 0.5,
            topP: chatRequest.top_p ?? 1.0,
            topK: chatRequest.top_k ?? 40,
            maxTokens: chatRequest.max_tokens ?? llm.maxTokens
        )

        do {
            let outputStream = try await llm.localhostGenerate(
                modelName: modelName,
                backend: backend,
                messages: messages,
                params: params
            )

            let requestID = "chatcmpl-\(UUID().uuidString.lowercased())"
            let created = Int(Date().timeIntervalSince1970)
            if chatRequest.stream == true {
                let stream = AsyncThrowingStream<String, Error> { continuation in
                    Task {
                        defer {
                            Task { await self.generationGate.release() }
                        }

                        do {
                            continuation.yield(Self.sseLine(for: OpenAIChatCompletionChunkResponse(
                                id: requestID,
                                created: created,
                                model: modelName,
                                choices: [
                                    OpenAIChatCompletionChunkChoice(
                                        index: 0,
                                        delta: OpenAIChatCompletionChunkDelta(role: "assistant", content: nil),
                                        finish_reason: nil
                                    )
                                ]
                            )))

                            var previous = ""
                            for try await output in outputStream {
                                let delta = String(output.dropFirst(previous.count))
                                previous = output
                                guard !delta.isEmpty else { continue }
                                continuation.yield(Self.sseLine(for: OpenAIChatCompletionChunkResponse(
                                    id: requestID,
                                    created: created,
                                    model: modelName,
                                    choices: [
                                        OpenAIChatCompletionChunkChoice(
                                            index: 0,
                                            delta: OpenAIChatCompletionChunkDelta(role: nil, content: delta),
                                            finish_reason: nil
                                        )
                                    ]
                                )))
                            }

                            continuation.yield(Self.sseLine(for: OpenAIChatCompletionChunkResponse(
                                id: requestID,
                                created: created,
                                model: modelName,
                                choices: [
                                    OpenAIChatCompletionChunkChoice(
                                        index: 0,
                                        delta: OpenAIChatCompletionChunkDelta(role: nil, content: nil),
                                        finish_reason: "stop"
                                    )
                                ]
                            )))
                            continuation.yield("data: [DONE]\n\n")
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }

                return LocalhostHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "text/event-stream; charset=utf-8",
                        "Cache-Control": "no-cache",
                        "Connection": "keep-alive"
                    ],
                    body: .sse(stream)
                )
            }

            var finalOutput = ""
            do {
                for try await output in outputStream {
                    finalOutput = output
                }
            } catch {
                await generationGate.release()
                return Self.errorResponse(status: 500, message: error.localizedDescription, type: "server_error")
            }

            await generationGate.release()
            return Self.jsonResponse(
                status: 200,
                payload: OpenAIChatCompletionResponse(
                    id: requestID,
                    created: created,
                    model: modelName,
                    choices: [
                        OpenAIChatCompletionChoice(
                            index: 0,
                            message: OpenAIAssistantMessage(role: "assistant", content: finalOutput),
                            finish_reason: "stop"
                        )
                    ]
                )
            )
        } catch {
            await generationGate.release()
            return Self.errorResponse(status: 500, message: error.localizedDescription, type: "server_error")
        }
    }

    nonisolated private static func jsonResponse<T: Encodable>(status: Int, payload: T) -> LocalhostHTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return LocalhostHTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: .data(data)
        )
    }

    nonisolated private static func errorResponse(status: Int, message: String, type: String) -> LocalhostHTTPResponse {
        jsonResponse(
            status: status,
            payload: OpenAIErrorEnvelope(error: OpenAIError(message: message, type: type))
        )
    }

    nonisolated private static func sseLine<T: Encodable>(for payload: T) -> String {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }
    #endif
}

private actor LocalhostGenerationGate {
    private var busy = false

    func acquire() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    func release() {
        busy = false
    }
}

#if os(macOS)
private struct LocalhostHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(from data: Data) throws -> LocalhostHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw NSError(domain: "LocalhostHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid HTTP headers"])
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw NSError(domain: "LocalhostHTTPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing request line"])
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            throw NSError(domain: "LocalhostHTTPServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "invalid request line"])
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])

        return LocalhostHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }
}

private enum LocalhostHTTPResponseBody: Sendable {
    case data(Data)
    case sse(AsyncThrowingStream<String, Error>)
}

private struct LocalhostHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: LocalhostHTTPResponseBody
}

private final class LocalhostHTTPServer: @unchecked Sendable {
    private let port: Int
    private let requestHandler: @Sendable (LocalhostHTTPRequest) async -> LocalhostHTTPResponse
    private let queue = DispatchQueue(label: "Lunar.LocalhostHTTPServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(
        port: Int,
        requestHandler: @escaping @Sendable (LocalhostHTTPRequest) async -> LocalhostHTTPResponse
    ) {
        self.port = port
        self.requestHandler = requestHandler
    }

    func start() async throws {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "LocalhostHTTPServer", code: 10, userInfo: [NSLocalizedDescriptionKey: "invalid localhost port"])
        }

        let listener = try NWListener(using: .tcp, on: endpointPort)
        self.listener = listener

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startState = LocalhostListenerStartState()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard startState.beginResume() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard startState.beginResume() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection: connection)
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(on: connection, buffer: Data())
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                AppLogger.localhost.error("localhost receive failed: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            do {
                if let request = try LocalhostHTTPRequest.parse(from: accumulated) {
                    Task {
                        let response = await self.requestHandler(request)
                        await self.send(response: response, on: connection)
                    }
                    return
                }
            } catch {
                Task {
                    await self.send(
                        response: LocalhostHTTPResponse(
                            statusCode: 400,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: .data(Data("{\"error\":{\"message\":\"invalid request\",\"type\":\"invalid_request_error\"}}".utf8))
                        ),
                        on: connection
                    )
                }
                return
            }

            if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: accumulated)
            }
        }
    }

    private func send(response: LocalhostHTTPResponse, on connection: NWConnection) async {
        do {
            switch response.body {
            case .data(let body):
                let headerData = try Self.headerData(
                    statusCode: response.statusCode,
                    headers: response.headers.merging(["Content-Length": "\(body.count)"]) { _, new in new }
                )
                try await send(data: headerData, on: connection)
                try await send(data: body, on: connection)
            case .sse(let stream):
                let headerData = try Self.headerData(statusCode: response.statusCode, headers: response.headers)
                try await send(data: headerData, on: connection)
                for try await chunk in stream {
                    try await send(data: Data(chunk.utf8), on: connection)
                }
            }
        } catch {
            AppLogger.localhost.error("localhost send failed: \(error.localizedDescription, privacy: .public)")
        }

        connection.cancel()
    }

    private func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func headerData(statusCode: Int, headers: [String: String]) throws -> Data {
        var lines = ["HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))"]
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        let joined = lines.joined(separator: "\r\n")
        guard let data = joined.data(using: .utf8) else {
            throw NSError(domain: "LocalhostHTTPServer", code: 11, userInfo: [NSLocalizedDescriptionKey: "invalid response headers"])
        }
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

private final class LocalhostListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func beginResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

private struct OpenAIModelsResponse: Encodable {
    let object = "list"
    let data: [OpenAIModelDescriptor]
}

private struct OpenAIModelDescriptor: Encodable {
    let id: String
    let object = "model"
    let created: Int
    let owned_by: String
}

private struct OpenAIChatCompletionRequest: Decodable {
    let model: String?
    let messages: [OpenAIChatMessage]
    let stream: Bool?
    let temperature: Float?
    let top_p: Float?
    let top_k: Int?
    let max_tokens: Int?
}

private struct OpenAIChatMessage: Decodable {
    let role: String
    let content: OpenAIChatMessageContent
}

private enum OpenAIChatMessageContent: Decodable {
    case string(String)
    case parts([OpenAIChatMessageContentPart])

    var flattenedText: String {
        switch self {
        case .string(let value):
            return value
        case .parts(let parts):
            return parts.compactMap(\.text).joined()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .parts(try container.decode([OpenAIChatMessageContentPart].self))
    }
}

private struct OpenAIChatMessageContentPart: Decodable {
    let type: String?
    let text: String?
}

private struct OpenAIChatCompletionResponse: Encodable {
    let id: String
    let object = "chat.completion"
    let created: Int
    let model: String
    let choices: [OpenAIChatCompletionChoice]
}

private struct OpenAIChatCompletionChoice: Encodable {
    let index: Int
    let message: OpenAIAssistantMessage
    let finish_reason: String?
}

private struct OpenAIAssistantMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIChatCompletionChunkResponse: Encodable {
    let id: String
    let object = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [OpenAIChatCompletionChunkChoice]
}

private struct OpenAIChatCompletionChunkChoice: Encodable {
    let index: Int
    let delta: OpenAIChatCompletionChunkDelta
    let finish_reason: String?
}

private struct OpenAIChatCompletionChunkDelta: Encodable {
    let role: String?
    let content: String?
}

private struct OpenAIErrorEnvelope: Encodable {
    let error: OpenAIError
}

private struct OpenAIError: Encodable {
    let message: String
    let type: String
}
#endif
