import SwiftUI
import Playgrounds

struct ContentView: View {
    /// Retains the WebSocket client and the session it feeds for the life of the app.
    @State private var live = LiveConnection()
    /// The host's room scan (MyApp/AR), opened from the lobby's "Scan room" button.
    @State private var showsRoomScan = false
    /// Relocalizes every phone into the host's scanned room and reports its tile (MyApp/AR). Manual tiles remain the fallback.
    @State private var position: PositionCoordinator

    init() {
        let live = LiveConnection()
        _live = State(initialValue: live)
        _position = State(initialValue: PositionCoordinator(ar: ARPositionProvider(client: live.client)))
    }

    var body: some View {
        // Real server by default. For UI work without a server, run a Debug build with the launch
        // argument `-useMock YES` (or any `-mockScenario <name>`, see MockLaunch).
        if Self.usesARDebug {
            ARDebugView()
        } else if Self.usesMock {
            RootView()
        } else {
            RootView(session: live.session, position: position, startRoomScan: { showsRoomScan = true })
                .fullScreenCover(isPresented: $showsRoomScan) {
                    RoomScanView(client: live.client, session: live.session)
                }
        }
    }

    private static var usesMock: Bool {
        #if DEBUG
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "useMock") || defaults.string(forKey: "mockScenario") != nil
        #else
        false
        #endif
    }

    /// Debug builds only: launch argument `-arDebug YES` opens the AR tracking harness instead of the game.
    private static var usesARDebug: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "arDebug")
        #else
        false
        #endif
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
