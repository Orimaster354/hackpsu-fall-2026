import SwiftUI

/// The shape of most screens: a scrolling column and one bar of actions. The bar is pinned to the
/// bottom, except at accessibility text sizes, where a pinned bar would cover half the screen and
/// hide the content it acts on. There it follows the content instead.
struct ScrollScreen<Content: View, Bar: View>: View {
    var spacing: CGFloat = 16
    var top: CGFloat = 16
    @ViewBuilder var content: Content
    @ViewBuilder var bar: Bar
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: spacing) {
                content
                if typeSize.isAccessibilitySize { bar }
            }
            // Bounds the column to the screen, so one wide child cannot push the rest off it.
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, top)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            if !typeSize.isAccessibilitySize {
                bar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                    .gameColumn()
            }
        }
        .gameColumn()
    }
}

/// A title with extras (tags, a status). Side by side when they fit. When large text leaves no
/// room, the extras move under the title instead of squeezing it into one letter per line.
struct SplitLine<Title: View, Extras: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var extras: Extras

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                extras
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                HStack(spacing: 8) { extras }
            }
        }
    }
}

/// A small label chip (Host, You, Voted). It never wraps: it is one short word.
struct Tag: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.14), in: Capsule())
    }
}
