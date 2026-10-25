import SwiftUI
import UIKit

/// The room code as four large tiles, with a copy button underneath.
struct RoomCodeBadge: View {
    let code: String
    @State private var copied = false
    @ScaledMetric(relativeTo: .largeTitle) private var letterSize: CGFloat = 40

    /// Follows Dynamic Type, but stops growing so four tiles always fit the column.
    private var tileLetterSize: CGFloat { min(letterSize, 64) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, letter in
                    Text(String(letter))
                        .font(.system(size: tileLetterSize, weight: .heavy, design: .monospaced))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(maxWidth: tileLetterSize * 1.4)
                        .frame(height: tileLetterSize * 1.8)
                        .gameCard(radius: Theme.Radius.control)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Room code, \(code.map(String.init).joined(separator: ", "))")

            Button {
                UIPasteboard.general.string = code
                copied = true
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        if copied {
                            Image(systemName: "checkmark").transition(IconSwap())
                        } else {
                            Image(systemName: "doc.on.doc").transition(IconSwap())
                        }
                    }
                    .animation(.iconSwap, value: copied)
                    Text(copied ? "Copied" : "Copy code")
                }
            }
            .buttonStyle(.game(.text))
            .accessibilityLabel(copied ? "Room code copied" : "Copy room code")
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        }
    }
}

/// An inline error: icon and text, never color alone. It is announced when it appears.
struct ErrorMessage: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.Palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}
