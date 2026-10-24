import Foundation

// UI-side shapes for the lobby and role screens. They carry only what these screens read.
// When `MyApp/Models` lands, the integration layer maps the wire models onto these and calls
// `GameSession.receive(_:)`, so the views do not change.
//
// Gaps in docs/architecture.md found while building this:
//  - `lobby` has no host id, so the host is taken to be players[0], the creator.
//  - There is no `ready` intent, so "ready" is derived from the player count.
//  - There is no `leave` intent, so leaving only resets the client and disconnects.
//  - `error` codes are not listed. The codes used by the mock are placeholders.

struct LobbyPlayer: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Raw values are the wire strings.
enum PlayerRole: String {
    case crew, impostor
}

/// Raw values are the wire strings.
enum GamePhase: String {
    case lobby, playing, meeting, ended
}

struct SessionError: Equatable {
    let code: String
    let message: String

    static let timeout = SessionError(
        code: "timeout",
        message: "The server did not answer. Check the server address in Settings."
    )
}

/// Client to server. Case names follow the `t` values in docs/architecture.md.
enum ClientIntent: Equatable {
    case create(name: String)
    case join(room: String, name: String)
    case start
}

/// Server to client. Case names follow the `t` values in docs/architecture.md.
enum ServerEvent: Equatable {
    case joined(playerID: String, room: String)
    case lobby(players: [LobbyPlayer])
    case role(PlayerRole)
    case state(phase: GamePhase)
    case error(SessionError)
}

enum RoomCode {
    static let length = 4

    /// Uppercases and keeps ASCII letters only, capped at `length`. Safe to call on every keystroke.
    static func clamp(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(length))
    }

    static func isValid(_ code: String) -> Bool {
        code.count == length && clamp(code) == code
    }
}

enum PlayerName {
    static let maxLength = 12

    /// Caps the length only, so a space can still be typed between two words.
    static func clamp(_ raw: String) -> String {
        String(raw.prefix(maxLength))
    }

    /// What gets sent to the server.
    static func normalized(_ raw: String) -> String {
        clamp(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isValid(_ name: String) -> Bool {
        !normalized(name).isEmpty
    }
}

/// `UserDefaults` keys shared by the settings and lobby screens. The network client reads
/// `serverAddress` (host or host:port, as typed by the user).
enum SettingsKey {
    static let playerName = "playerName"
    static let serverAddress = "serverAddress"
}
