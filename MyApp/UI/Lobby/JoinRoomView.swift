import SwiftUI

struct JoinRoomView: View {
    @Environment(GameSession.self) private var session
    @AppStorage(SettingsKey.playerName) private var name = ""
    @State private var code = ""
    @FocusState private var codeFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var codeSize: CGFloat = 52

    private var isJoining: Bool { session.pending == .join }
    private var canJoin: Bool { RoomCode.isValid(code) && PlayerName.isValid(name) && session.pending == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Enter the room code")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("It is the four letters on the host's screen.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .multilineTextAlignment(.center)
                .staggeredEntrance(0)

                TextField("Room code", text: $code, prompt: Text("ABCD").foregroundStyle(Theme.Palette.placeholder))
                    .font(.system(size: codeSize, weight: .heavy, design: .monospaced))
                    .tracking(codeSize * 0.2)
                    .multilineTextAlignment(.center)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .focused($codeFocused)
                    .padding(.vertical, 20)
                    .gameCard(radius: Theme.Radius.control)
                    .onChange(of: code) {
                        code = RoomCode.clamp(code)
                        session.dismissError()
                    }
                    .onSubmit(join)
                    .accessibilityIdentifier("roomCodeField")
                    .staggeredEntrance(1)

                if let error = session.error {
                    ErrorMessage(text: error.message)
                }

                Button(action: join) {
                    BusyLabel(title: "Join", busyTitle: "Joining…", isBusy: isJoining)
                }
                .buttonStyle(.game(.primary, busy: isJoining))
                .disabled(!canJoin)
                .accessibilityIdentifier("joinButton")
                .staggeredEntrance(2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .gameColumn()
        .navigationTitle("Join room")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
        .task { codeFocused = true }
        .onDisappear { session.dismissError() }
    }

    private func join() {
        guard canJoin else { return }
        session.joinRoom(code: code, name: name)
    }
}

#Preview("Join") {
    RootView(session: .mock(.join), homePath: [.join])
}
