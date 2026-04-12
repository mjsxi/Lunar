import OSLog

enum AppLogger {
    static let general = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lunar", category: "general")
    static let inference = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lunar", category: "inference")
    static let knowledgeBase = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lunar", category: "knowledge-base")
    static let pythonBackend = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lunar", category: "python-backend")
    static let localhost = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lunar", category: "localhost")
}
