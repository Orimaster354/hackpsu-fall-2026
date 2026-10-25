import SwiftUI

/// The Blindspot mark: a space-helmet visor in crew blue with a red eye watching from the glass,
/// the thing in your blind spot. It is drawn from shapes, so the app icon is rendered from this
/// same view (`Tools/AppIcon`). The eye's `lookX`, `lookY` and `lid` are plain inputs so the home
/// screen can animate them (`BlindspotLogo`). The dark lip under the helmet is the same raised-slab
/// edge the buttons use.
struct BlindspotMark: View {
    var size: CGFloat = 120
    /// Where the eye looks, from -1 (left) to 1 (right) and from -1 (up) to 1 (down).
    var lookX: CGFloat = -0.55
    var lookY: CGFloat = 0.1
    /// How open the eye is: 1 is open, about 0.06 is closed.
    var lid: CGFloat = 1
    /// The four AR viewfinder corners around the visor.
    var brackets = true
    var glow = true
    /// Grayscale only, for the tinted app icon.
    var mono = false

    private var ink: Ink { mono ? .mono : .color }

    var body: some View {
        let u = size / 100
        ZStack {
            if glow {
                Circle()
                    .fill(RadialGradient(colors: [ink.halo.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 50 * u))
                    .frame(width: 100 * u, height: 100 * u)
                    .offset(y: -3 * u)
            }
            if brackets {
                ViewfinderCorners()
                    .stroke(ink.bracket, style: StrokeStyle(lineWidth: 3.4 * u, lineCap: .round, lineJoin: .round))
                    .frame(width: 100 * u, height: 100 * u)
            }
            helmet(u)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Drawing (100 units square, so `u` is one percent of the size)

    private func helmet(_ u: CGFloat) -> some View {
        let rim = RoundedRectangle(cornerRadius: 25 * u, style: .continuous)
        let glass = RoundedRectangle(cornerRadius: 20 * u, style: .continuous)
        return ZStack {
            rim.fill(ink.lip)
                .frame(width: 74 * u, height: 55 * u)
                .offset(y: 5 * u)
            rim.fill(LinearGradient(colors: [ink.rimTop, ink.rimMid, ink.rimBottom], startPoint: .top, endPoint: .bottom))
                .overlay {
                    rim.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0)], startPoint: .top, endPoint: .center),
                        lineWidth: 1.4 * u
                    )
                }
                .frame(width: 74 * u, height: 55 * u)
            visorGlass(u)
                .frame(width: 64 * u, height: 45 * u)
                .clipShape(glass)
                .overlay { glass.strokeBorder(Color.black.opacity(0.35), lineWidth: 1.2 * u) }
        }
        .offset(y: -3 * u)
    }

    private func visorGlass(_ u: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(LinearGradient(stops: ink.glass, startPoint: .top, endPoint: .bottom))
            // The lower half sinks into shadow, which is what makes the glass read as curved.
            Rectangle().fill(LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom))
            eye(u)
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.06)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 30 * u, height: 7.5 * u)
                .rotationEffect(.degrees(-16))
                .offset(x: -14 * u, y: -14.5 * u)
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: 3.6 * u, height: 3.6 * u)
                .offset(x: -26 * u, y: -6 * u)
        }
    }

    private func eye(_ u: CGFloat) -> some View {
        let travel = 3.4 * u
        let gaze = CGSize(width: lookX * travel, height: lookY * travel)
        return ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [ink.eyeBloom.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 21 * u))
                .frame(width: 44 * u, height: 48 * u)
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [ink.socketCenter, ink.socketEdge], center: .center, startRadius: 0, endRadius: 15 * u))
                    .overlay { Ellipse().strokeBorder(ink.ring, lineWidth: 1.7 * u) }
                    .frame(width: 24 * u, height: 28 * u)
                Circle()
                    .fill(RadialGradient(colors: ink.iris, center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 8.5 * u))
                    .frame(width: 16 * u, height: 16 * u)
                    .offset(gaze)
                Capsule()
                    .fill(Color(.sRGB, red: 0.05, green: 0.01, blue: 0.03))
                    .frame(width: 3.4 * u, height: 11 * u)
                    .offset(gaze)
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 3.2 * u, height: 3.2 * u)
                    .offset(x: gaze.width * 0.8 - 2.6 * u, y: gaze.height * 0.8 - 3.2 * u)
            }
            .scaleEffect(x: 1, y: lid, anchor: .center)
        }
        .offset(x: 15 * u, y: 2 * u)
    }
}

/// The mark's colors. `color` is the real thing, `mono` the grayscale set for the tinted icon.
private struct Ink {
    var rimTop, rimMid, rimBottom, lip: Color
    var glass: [Gradient.Stop]
    var socketCenter, socketEdge, ring: Color
    var iris: [Color]
    var halo, eyeBloom, bracket: Color

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static let color = Ink(
        rimTop: hex(0x5266AD), rimMid: hex(0x222E63), rimBottom: hex(0x111833), lip: hex(0x070B1C),
        glass: [
            .init(color: hex(0xD3EDFF), location: 0),
            .init(color: hex(0x74BBFF), location: 0.32),
            .init(color: hex(0x2F6BEA), location: 0.72),
            .init(color: hex(0x1A3AA0), location: 1),
        ],
        socketCenter: hex(0x2A0914), socketEdge: hex(0x0B0308), ring: hex(0xFF5A6B),
        iris: [hex(0xFFC2C9), hex(0xFF4F66), hex(0xC8283D)],
        halo: hex(0x5BB0FF), eyeBloom: hex(0xFF5A6B), bracket: Color.white.opacity(0.3)
    )

    static let mono = Ink(
        rimTop: hex(0x8A8A8A), rimMid: hex(0x3A3A3A), rimBottom: hex(0x1C1C1C), lip: hex(0x0A0A0A),
        glass: [
            .init(color: hex(0xFFFFFF), location: 0),
            .init(color: hex(0xE0E0E0), location: 0.32),
            .init(color: hex(0xA0A0A0), location: 0.72),
            .init(color: hex(0x6E6E6E), location: 1),
        ],
        socketCenter: hex(0x303030), socketEdge: hex(0x0A0A0A), ring: Color.white.opacity(0.9),
        iris: [hex(0xFFFFFF), hex(0xF2F2F2), hex(0xBDBDBD)],
        halo: Color.white.opacity(0.5), eyeBloom: Color.white.opacity(0.8), bracket: Color.white.opacity(0.4)
    )
}

private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.04
        let arm = rect.width * 0.15
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX + inset, y: rect.minY + inset), 1, 1),
            (CGPoint(x: rect.maxX - inset, y: rect.minY + inset), -1, 1),
            (CGPoint(x: rect.minX + inset, y: rect.maxY - inset), 1, -1),
            (CGPoint(x: rect.maxX - inset, y: rect.maxY - inset), -1, -1),
        ]
        var path = Path()
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        return path
    }
}

/// "BLINDSPOT" in chunky rounded capitals with a dark lip under the letters, like the buttons.
struct BlindspotWordmark: View {
    @ScaledMetric(relativeTo: .largeTitle) private var fontSize: CGFloat = 36

    private var depth: CGFloat { min(fontSize, 56) * 0.09 }

    var body: some View {
        let font = Font.system(size: min(fontSize, 56), weight: .black, design: .rounded)
        ZStack {
            Text("BLINDSPOT")
                .foregroundStyle(Color(.sRGB, red: 0.07, green: 0.20, blue: 0.55))
                .offset(y: depth)
            Text("BLINDSPOT")
                .foregroundStyle(LinearGradient(
                    colors: [.white, Color(.sRGB, red: 0.75, green: 0.89, blue: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
        }
        .font(font)
        .tracking(2.5)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.bottom, depth)
        .shadow(color: Color(.sRGB, red: 0.36, green: 0.69, blue: 1).opacity(0.35), radius: 14)
        .accessibilityLabel("Blindspot")
    }
}
