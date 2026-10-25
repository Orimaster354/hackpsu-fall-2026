import SwiftUI

// Motion for infrequent moments only (screen changes, the role reveal, copying a code).
// Enter: opacity, 4pt blur, 12pt rise over 300ms. Exit: the same, 12pt up, over 150ms.
// Enters take 300ms and exits 150ms, set per transition, never one duration for both.
// Under Reduce Motion everything becomes a plain opacity cross-fade.

/// Opacity, 4pt blur and 12pt of travel. Enters from below, leaves upward.
struct BlurRise: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(BlurRiseEffect(phase: phase))
    }
}

private struct BlurRiseEffect: ViewModifier {
    let phase: TransitionPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let offset: CGFloat = switch phase {
        case .willAppear: 12
        case .identity: 0
        case .didDisappear: -12
        }
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity || reduceMotion ? 0 : 4)
            .offset(y: reduceMotion ? 0 : offset)
    }
}

enum Motion {
    /// A whole-screen swap. The new screen fades in over 300ms and staggers its own content in,
    /// and the old one leaves like any exit: opacity, 4pt blur, 12pt up, 150ms.
    static var screen: some Transition {
        AsymmetricTransition(
            insertion: OpacityTransition().animation(.easeOut(duration: 0.3)),
            removal: BlurRise().animation(.easeOut(duration: 0.15))
        )
    }

    /// A swap inside a card: 300ms in, 150ms out, each with its own animation.
    static var swap: some Transition {
        AsymmetricTransition(
            insertion: BlurRise().animation(.easeOut(duration: 0.3)),
            removal: BlurRise().animation(.easeOut(duration: 0.15))
        )
    }
}

/// Swaps one contextual icon for another (copy to copied): scale 0.25 to 1, opacity, 4pt blur.
struct IconSwap: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(IconSwapEffect(isIdentity: phase.isIdentity))
    }
}

private struct IconSwapEffect: ViewModifier {
    let isIdentity: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isIdentity ? 1 : 0)
            .scaleEffect(isIdentity || reduceMotion ? 1 : 0.25)
            .blur(radius: isIdentity || reduceMotion ? 0 : 4)
    }
}

extension Animation {
    /// For icon swaps. Bounce is always 0.
    static let iconSwap = Animation.spring(duration: 0.3, bounce: 0)
}

private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 4)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3).delay(0.1 * Double(index))) { shown = true }
            }
    }
}

extension View {
    /// Fades a chunk of a screen in 100ms after the previous one. Index 0 enters first.
    func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}
