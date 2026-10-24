import SwiftUI

// Motion for infrequent moments only (screen changes, the role reveal, copying a code).
// Enter: opacity, 4pt blur, 12pt rise over 300ms. Exit: the same, 12pt up, over 150ms.
// Whole-screen swaps are a plain opacity cross-fade, because each screen staggers its own content in.
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
