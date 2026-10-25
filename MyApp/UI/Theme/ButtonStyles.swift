import SwiftUI

/// One button style for the whole app: a deep-navy glass face with a bright edge, sitting on a
/// glowing base plate, the same raised look as the logo. Pressing sinks the face onto the plate
/// and scales the button to 0.96 over 150ms (ease-out). A disabled button never moves, and under
/// Reduce Motion the press dims instead of moving. Primary buttons take their color from `tint`,
/// so the red emergency buttons use the same style in crimson.
struct GameButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text }

    var kind: Kind = .primary
    var tint: Color = Theme.Palette.glow
    /// A request is in flight: keep the full-strength look instead of the dimmed disabled one.
    var isBusy = false
    /// Opt out where the motion would distract.
    var scalesOnPress = true

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let dimmed = !isEnabled && !isBusy

        Group {
            switch kind {
            case .primary:
                configuration.label
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)
                    .slabSurface(tint: tint, pressed: pressed, dimmed: dimmed)
            case .secondary:
                configuration.label
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .slabSurface(tint: tint, style: .glass, pressed: pressed, dimmed: dimmed)
            case .text:
                configuration.label
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.Palette.textSecondary.opacity(dimmed ? 0.55 : 1))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
        }
        .scaleEffect(pressed && scalesOnPress && !reduceMotion ? 0.96 : 1)
        .opacity(pressed && (reduceMotion || !scalesOnPress || kind == .text) ? 0.7 : 1)
        .animation(.easeOut(duration: 0.15), value: pressed)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: pressed) { _, now in now && kind != .text }
    }
}

extension ButtonStyle where Self == GameButtonStyle {
    /// `.buttonStyle(.game(.primary, busy: session.pending == .create))`
    static func game(_ kind: GameButtonStyle.Kind, busy: Bool = false, tint: Color = Theme.Palette.glow) -> GameButtonStyle {
        GameButtonStyle(kind: kind, tint: tint, isBusy: busy)
    }
}

/// Press feedback for tappable rows (a vote candidate, a station in the setup list): the row
/// shrinks to 0.98 over 150ms. Rows are wide, so they scale less than buttons do.
struct GameRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .opacity(pressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: pressed)
    }
}

extension ButtonStyle where Self == GameRowStyle {
    static var gameRow: GameRowStyle { GameRowStyle() }
}

/// The raised look every button shares: a dark face over a glowing base plate (the "lip"). The
/// face sinks onto the plate while `pressed`. `solid` is the tinted face, `glass` the quiet one for
/// secondary actions. A `progress` fills the face from the left, for the hold-to-confirm button.
struct SlabSurface: ViewModifier {
    enum Style { case solid, glass }

    var tint: Color
    var style = Style.solid
    var pressed = false
    var dimmed = false
    var progress: Double?
    /// How the fill moves. Set here, on the fill itself, so it keeps its own timing when the press
    /// animation (150ms) runs in the same update: an outer animation would otherwise replace it.
    var progressAnimation: Animation?
    var minHeight: CGFloat = 56

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the lip shows below the face.
    static let depth: CGFloat = 5

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background { face }
            .offset(y: pressed && !reduceMotion ? Self.depth * 0.6 : 0)
            .background(alignment: .top) { lip.offset(y: Self.depth) }
            .padding(.bottom, Self.depth)
            .opacity(dimmed ? 0.5 : 1)
    }

    /// Deep tint-colored navy, a little lighter at the top. White text on it is far above 4.5:1.
    private var gradient: LinearGradient {
        LinearGradient(colors: [tint.slabFaceTop, tint.slabFaceBottom], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private var face: some View {
        switch style {
        case .solid:
            ZStack(alignment: .leading) {
                Rectangle().fill(gradient)
                if let progress {
                    // The face starts dark and fills with the bright tint as you hold.
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(LinearGradient(colors: [tint.slabFillTop, tint.slabFillBottom], startPoint: .top, endPoint: .bottom))
                            .frame(width: proxy.size.width * progress)
                            .animation(progressAnimation, value: progress)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                // A bright rim that fades down the sides, like light catching the top edge.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [tint.slabEdge.opacity(pressed ? 1 : 0.9), tint.slabEdge.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
            }
            .overlay(alignment: .top) {
                // A thin inner highlight under the rim.
                Capsule()
                    .fill(LinearGradient(colors: [.clear, Color.white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .padding(.horizontal, Theme.Radius.control)
                    .padding(.top, 2.5)
            }
        case .glass:
            // Dark glass edged in the tint, so the quiet button still belongs to the same family.
            shape
                .fill(LinearGradient(colors: [tint.slabFaceTop.opacity(0.55), tint.slabFaceBottom.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                .overlay { shape.strokeBorder(tint.slabEdge.opacity(pressed ? 0.75 : 0.45), lineWidth: 1) }
        }
    }

    private var lip: some View {
        shape
            .fill(style == .solid ? tint.slabLip : tint.mix(with: .black, by: 0.6).opacity(0.8))
            .shadow(color: dimmed || style == .glass ? .clear : tint.opacity(pressed ? 0.25 : 0.42), radius: 16, y: 7)
    }
}

extension Color {
    /// The shades of one slab, derived from its tint so every button, and the kill knob, stay one
    /// family: a deep face (lighter at the top), a bright edge, and a glowing plate under it.
    var slabFaceTop: Color { mix(with: .black, by: 0.5) }
    var slabFaceBottom: Color { mix(with: .black, by: 0.76) }
    var slabEdge: Color { mix(with: .white, by: 0.42) }
    /// What a hold-to-confirm button fills with.
    var slabFillTop: Color { mix(with: .black, by: 0.12) }
    var slabFillBottom: Color { mix(with: .black, by: 0.4) }
    var slabLip: Color { mix(with: .black, by: 0.3) }
}

extension View {
    func slabSurface(
        tint: Color,
        style: SlabSurface.Style = .solid,
        pressed: Bool = false,
        dimmed: Bool = false,
        progress: Double? = nil,
        progressAnimation: Animation? = nil
    ) -> some View {
        modifier(SlabSurface(
            tint: tint, style: style, pressed: pressed, dimmed: dimmed,
            progress: progress, progressAnimation: progressAnimation
        ))
    }
}

/// Button label that swaps to a spinner and a progress word while a request is in flight.
struct BusyLabel: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isBusy { ProgressView().tint(.white) }
            Text(isBusy ? busyTitle : title)
        }
    }
}
