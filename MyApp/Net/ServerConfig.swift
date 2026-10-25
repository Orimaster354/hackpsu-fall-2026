import Foundation

/// Resolves the server address typed in Settings into WebSocket and HTTP URLs.
///
/// Physical iPhones reach the laptop over the hotspot, so the address is user-configurable.
/// `UserDefaults` key `serverAddress` is shared with the settings screen (`SettingsKey.serverAddress`
/// in MyApp/UI/Session/SessionModels.swift).
enum ServerConfig {
    static let defaultsKey = "serverAddress"
    static let defaultPort = 8080
    /// Used only when nothing is configured. Works in the Simulator, never on a real iPhone.
    static let fallbackAddress = "localhost:8080"

    struct Endpoint: Equatable {
        var host: String
        var port: Int

        var webSocketURL: URL? { URL(string: "ws://\(authority)/ws") }
        var httpBase: String { "http://\(authority)" }

        func mapURL(room: String) -> URL? { URL(string: "\(httpBase)/map/\(room)") }

        private var authority: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    }

    /// Accepts `192.168.1.20`, `192.168.1.20:8080`, `ws://host:8080`, `http://host`, with or without a
    /// trailing path. Returns nil for an empty or unusable string.
    static func parse(_ raw: String) -> Endpoint? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        guard !text.isEmpty else { return nil }

        // Bracketed IPv6 literal, optionally followed by :port.
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return Endpoint(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
            return Endpoint(host: host, port: port)
        }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return Endpoint(host: String(parts[0]), port: defaultPort)
        case 2:
            guard !parts[0].isEmpty, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
            return Endpoint(host: String(parts[0]), port: port)
        default:
            return nil
        }
    }

    /// The configured endpoint, or the Simulator fallback when nothing is set.
    static func current(defaults: UserDefaults = .standard) -> Endpoint? {
        let stored = defaults.string(forKey: defaultsKey) ?? ""
        return parse(stored.isEmpty ? fallbackAddress : stored)
    }
}
