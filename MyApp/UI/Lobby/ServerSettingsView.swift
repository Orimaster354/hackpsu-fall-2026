import SwiftUI

/// The README asks players to enter the laptop's LAN IP in the app's settings. The address is stored
/// under `SettingsKey.serverAddress` for the network client to read.
struct ServerSettingsView: View {
    @Environment(GameSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.serverAddress) private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $address, prompt: Text("192.168.1.20:8080"))
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("serverAddressField")
                } header: {
                    Text("Server address")
                } footer: {
                    Text("The laptop's IP address on the phone hotspot. The server listens on port 8080.")
                }

                Section("Connection") {
                    LabeledContent("Using", value: session.transportName)
                }
            }
            .scrollContentBackground(.hidden)
            .background { GameBackdrop().ignoresSafeArea() }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

#Preview("Server settings") {
    ServerSettingsView()
        .environment(GameSession.mock(.home))
}
