import SwiftUI
import Playgrounds

struct ContentView: View {
    /// Retains the WebSocket client and the session it feeds for the life of the app.
    @State private var live = LiveConnection()

    var body: some View {
        // Real server by default. For UI work without a server, run a Debug build with the launch
        // argument `-useMock YES` (or any `-mockScenario <name>`, see MockLaunch).
        if Self.usesMock {
            RootView()
        } else {
            // The AR module adds `position:` and `startRoomScan:` here when it is ready.
            RootView(session: live.session)
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
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
