import SwiftUI

enum HomeRoute: Hashable {
    case join
}

/// Everything before a room exists: pick a name, then create a room or join one.
struct HomeFlow: View {
    @Binding var path: [HomeRoute]

    var body: some View {
        NavigationStack(path: $path) {
            LobbyHomeView { path.append(.join) }
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .join: JoinRoomView()
                    }
                }
                .containerBackground(.clear, for: .navigation)
        }
    }
}

struct LobbyHomeView: View {
    @Environment(GameSession.self) private var session
    @AppStorage(SettingsKey.playerName) private var name = ""
    @State private var showSettings = false
    let onJoin: () -> Void

    private var isCreating: Bool { session.pending == .create }
    private var canContinue: Bool { PlayerName.isValid(name) && session.pending == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header.staggeredEntrance(0)
                nameField.staggeredEntrance(1)

                VStack(spacing: 12) {
                    Button { session.createRoom(name: name) } label: {
                        BusyLabel(title: "Create room", busyTitle: "Creating…", isBusy: isCreating)
                    }
                    .buttonStyle(.game(.primary, busy: isCreating))
                    .accessibilityIdentifier("createRoomButton")

                    Button { session.createRoom(name: name, demo: true) } label: {
                        Label("Create demo room", systemImage: "gamecontroller.fill")
                    }
                    .buttonStyle(.game(.secondary))
                    .accessibilityIdentifier("createDemoRoomButton")
                    Text("No scan · Editable task map · Manual movement · 4 players")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)

                    Button("Join room", action: onJoin)
                        .buttonStyle(.game(.secondary))
                        .accessibilityIdentifier("joinRoomButton")
                }
                .disabled(!canContinue)
                .staggeredEntrance(2)

                if let error = session.error {
                    ErrorMessage(text: error.message)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) { serverRow }
        .gameColumn()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) { ServerSettingsView() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            BlindspotLogo()
            Text("Find the impostor in a real room.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
            TextField("Your name", text: $name, prompt: Text("Enter a name").foregroundStyle(Theme.Palette.placeholder))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(16)
                .gameCard(radius: Theme.Radius.control)
                .onChange(of: name) { name = PlayerName.clamp(name) }
                .accessibilityIdentifier("nameField")
            Text("Other players see this. Up to \(PlayerName.maxLength) characters.")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var serverRow: some View {
        Button { showSettings = true } label: {
            Label(session.transportName, systemImage: "network")
                .font(.footnote.weight(.medium))
        }
        .buttonStyle(.game(.text))
        .accessibilityLabel("Server settings")
        .accessibilityValue(session.transportName)
        .padding(.bottom, 4)
    }
}

#Preview("Home") {
    RootView(session: .mock(.home))
}
