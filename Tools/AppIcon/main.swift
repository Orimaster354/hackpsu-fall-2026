import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Renders the Blindspot app icon from `BlindspotMark`, the same view the home screen draws, so the
// icon and the in-app logo cannot drift apart. Usage: make_app_icon <AppIcon.appiconset directory>.
// Writes three opaque 1024 px PNGs: the normal icon, the dark one and the grayscale one for tinted mode.

enum Variant: String, CaseIterable {
    case any = "AppIcon-1024.png"
    case dark = "AppIcon-dark.png"
    case tinted = "AppIcon-tinted.png"
}

/// Floor tiles: the game is played on a 1 m grid, so the icon sits on one, very faintly.
private struct TileGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / 8
        for index in 1 ..< 8 {
            let offset = step * CGFloat(index)
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + offset))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
        }
        return path
    }
}

struct IconArt: View {
    let variant: Variant

    private func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    private var background: LinearGradient {
        switch variant {
        case .any: LinearGradient(colors: [hex(0x14214F), hex(0x0A1130), hex(0x03050F)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dark: LinearGradient(colors: [hex(0x0B1235), hex(0x060A1F), hex(0x020309)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .tinted: LinearGradient(colors: [hex(0x202020), hex(0x050505), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// A violet glow in one corner and a cyan one in the other, like the nebula in the app.
    private func nebula(_ color: Color, x: CGFloat, y: CGFloat, radius: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .position(x: x, y: y)
    }

    /// Stars big enough to survive being shrunk to a home screen icon. Seeded, so the icon is the
    /// same every time it is rendered.
    private var stars: some View {
        var generator = IconRandom(seed: 7)
        let points: [(CGFloat, CGFloat, CGFloat, Double)] = (0 ..< 46).map { _ in
            (.random(in: 40 ... 984, using: &generator), .random(in: 40 ... 984, using: &generator),
             .random(in: 2 ... 6.5, using: &generator), .random(in: 0.25 ... 0.85, using: &generator))
        }
        return ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { _, star in
                Circle()
                    .fill(Color.white.opacity(star.3))
                    .frame(width: star.2 * 2, height: star.2 * 2)
                    .position(x: star.0, y: star.1)
            }
        }
    }

    var body: some View {
        ZStack {
            background
            if variant != .tinted {
                nebula(hex(0x7B5CFF), x: 190, y: 170, radius: 560, opacity: variant == .dark ? 0.32 : 0.42)
                nebula(hex(0x3DDCFF), x: 860, y: 900, radius: 520, opacity: variant == .dark ? 0.2 : 0.28)
            }
            stars.opacity(variant == .tinted ? 0.7 : 1)
            TileGrid()
                .stroke(Color.white.opacity(variant == .tinted ? 0.09 : 0.045), lineWidth: 2)
            // The viewfinder corners sit about 11 percent in from each edge, clear of the corner
            // rounding iOS applies to the icon.
            BlindspotMark(size: 1024 * 0.84, mono: variant == .tinted)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func writeOpaquePNG(_ art: IconArt, to url: URL) throws {
    let renderer = ImageRenderer(content: art)
    renderer.scale = 1
    guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    // Redraw into a context with no alpha channel: app icons must be fully opaque.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let opaque = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, opaque, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

guard CommandLine.arguments.count == 2 else {
    print("usage: make_app_icon <AppIcon.appiconset directory>")
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try MainActor.assumeIsolated {
    for variant in Variant.allCases {
        let url = directory.appendingPathComponent(variant.rawValue)
        try writeOpaquePNG(IconArt(variant: variant), to: url)
        print("wrote \(url.path)")
    }
}

/// A tiny deterministic generator (SplitMix64), so the star field never changes between runs.
struct IconRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
