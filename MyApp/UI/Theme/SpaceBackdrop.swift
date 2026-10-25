import SwiftUI

/// The space-cyberpunk backdrop, drawn live so it stays sharp at any size and costs no image
/// assets: a deep gradient, a nebula, a parallax starfield with the odd shooting star, and on the
/// quiet screens a ringed planet and a neon grid horizon. Each screen gets its own scene, and
/// `RootView` cross-fades between them. Gameplay is drawn still, to save battery on a screen that
/// is on for the whole round. Under Reduce Motion everything is still.
struct SpaceBackdrop: View {
    enum Scene: Hashable {
        case home, lobby, game, meeting, crewWins, impostorWins
    }

    var scene: Scene = .game
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animated || reduceMotion)) { timeline in
            SpaceCanvas(scene: scene, time: animated && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// One frame of the backdrop at `time` seconds. Separate from `SpaceBackdrop` so a still can be
/// drawn for any moment.
struct SpaceCanvas: View {
    let scene: SpaceBackdrop.Scene
    var time: Double = 0

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
    }

    // MARK: Look of each scene

    private struct Cloud {
        var x, y, radius: CGFloat
        var color: Color
        var opacity: Double
    }

    private struct Planet {
        var x, y, radius: CGFloat
        var ring: Bool
    }

    private struct Look {
        var clouds: [Cloud]
        var planet: Planet?
        /// Where the neon floor starts, as a fraction of the height, and its color. Nil for none.
        var horizon: CGFloat?
        var grid: Color = Theme.Palette.neon
    }

    private var look: Look {
        switch scene {
        case .home:
            Look(
                clouds: [
                    Cloud(x: 0.12, y: 0.16, radius: 0.85, color: Theme.Palette.violet, opacity: 0.3),
                    Cloud(x: 0.88, y: 0.5, radius: 0.8, color: Theme.Palette.glow, opacity: 0.22),
                    Cloud(x: 0.5, y: 0.95, radius: 0.7, color: Theme.Palette.magenta, opacity: 0.16),
                ],
                planet: Planet(x: 0.93, y: 0.15, radius: 0.4, ring: true),
                horizon: 0.78
            )
        case .lobby:
            Look(
                clouds: [
                    Cloud(x: 0.85, y: 0.1, radius: 0.8, color: Theme.Palette.glow, opacity: 0.26),
                    Cloud(x: 0.08, y: 0.65, radius: 0.8, color: Theme.Palette.neon, opacity: 0.13),
                    Cloud(x: 0.7, y: 0.95, radius: 0.6, color: Theme.Palette.violet, opacity: 0.2),
                ],
                planet: Planet(x: 0.08, y: 0.07, radius: 0.2, ring: false),
                horizon: 0.88
            )
        case .game:
            Look(
                clouds: [
                    Cloud(x: 0.5, y: 0.25, radius: 0.9, color: Theme.Palette.glow, opacity: 0.12),
                    Cloud(x: 0.92, y: 0.85, radius: 0.7, color: Theme.Palette.violet, opacity: 0.12),
                ],
                planet: nil,
                horizon: nil
            )
        case .meeting:
            Look(
                clouds: [
                    Cloud(x: 0.5, y: 0.05, radius: 0.95, color: Theme.Palette.emergency, opacity: 0.32),
                    Cloud(x: 0.1, y: 0.8, radius: 0.7, color: Theme.Palette.magenta, opacity: 0.16),
                ],
                planet: nil,
                horizon: 0.9,
                grid: Theme.Palette.impostor
            )
        case .crewWins:
            Look(
                clouds: [
                    Cloud(x: 0.5, y: 0.15, radius: 0.95, color: Theme.Palette.neon, opacity: 0.3),
                    Cloud(x: 0.15, y: 0.75, radius: 0.7, color: Theme.Palette.success, opacity: 0.14),
                ],
                planet: nil,
                horizon: 0.86
            )
        case .impostorWins:
            Look(
                clouds: [
                    Cloud(x: 0.5, y: 0.15, radius: 0.95, color: Theme.Palette.impostor, opacity: 0.32),
                    Cloud(x: 0.85, y: 0.75, radius: 0.7, color: Theme.Palette.violet, opacity: 0.2),
                ],
                planet: nil,
                horizon: 0.86,
                grid: Theme.Palette.impostor
            )
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let look = look
        let rect = CGRect(origin: .zero, size: size)

        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [Theme.Palette.backgroundTop, Theme.Palette.backgroundBottom]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: h)
            )
        )

        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            for (index, cloud) in look.clouds.enumerated() {
                let drift = CGFloat(sin(time * 0.07 + Double(index) * 2.1)) * 0.025
                let center = CGPoint(x: (cloud.x + drift) * w, y: cloud.y * h)
                let radius = cloud.radius * w
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        Gradient(colors: [cloud.color.opacity(cloud.opacity), cloud.color.opacity(cloud.opacity * 0.35), cloud.color.opacity(0)]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }

        drawStars(&context, size: size)
        if scene != .game { drawShootingStar(&context, size: size) }
        if let planet = look.planet { drawPlanet(&context, planet, size: size) }
        if let horizon = look.horizon { drawGrid(&context, horizon: horizon * h, color: look.grid, size: size) }

        // Dark edges keep the content legible and pull the eye to the middle.
        context.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [.clear, Color.black.opacity(0.55)]),
                center: CGPoint(x: w / 2, y: h * 0.45),
                startRadius: min(w, h) * 0.4,
                endRadius: max(w, h) * 0.85
            )
        )
    }

    private func drawStars(_ context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        for star in Self.stars {
            let drift = CGFloat((time * star.drift).truncatingRemainder(dividingBy: 1))
            var x = star.x + drift
            if x > 1 { x -= 1 }
            let twinkle = star.twinkles ? 0.62 + 0.38 * sin(time * star.speed + star.phase) : 1
            let alpha = star.opacity * twinkle
            let center = CGPoint(x: x * w, y: star.y * h)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - star.radius, y: center.y - star.radius, width: star.radius * 2, height: star.radius * 2)),
                with: .color(star.color.opacity(alpha))
            )
            if star.sparkle {
                let arm = star.radius * 4.5
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - arm, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - arm))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
                context.stroke(cross, with: .color(star.color.opacity(alpha * 0.55)), lineWidth: 0.6)
            }
        }
    }

    /// One streak across the sky every nine seconds, from a different spot each time.
    private func drawShootingStar(_ context: inout GraphicsContext, size: CGSize) {
        guard time > 0 else { return }
        let cycle = 9.0, duration = 0.75
        let phase = time.truncatingRemainder(dividingBy: cycle) / duration
        guard phase < 1 else { return }
        var generator = SeededRandom(seed: UInt64(time / cycle) &+ 17)
        let startX = CGFloat.random(in: 0.35 ... 0.95, using: &generator) * size.width
        let startY = CGFloat.random(in: 0.04 ... 0.3, using: &generator) * size.height
        let dx = -size.width * 0.38, dy = size.height * 0.1
        let head = CGPoint(x: startX + dx * phase, y: startY + dy * phase)
        let tail = CGPoint(x: head.x - dx * 0.22, y: head.y - dy * 0.22)
        let fade = sin(phase * .pi)
        var streak = Path()
        streak.move(to: tail)
        streak.addLine(to: head)
        context.stroke(
            streak,
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.9 * fade)]),
                startPoint: tail,
                endPoint: head
            ),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
        )
    }

    private func drawPlanet(_ context: inout GraphicsContext, _ planet: Planet, size: CGSize) {
        let w = size.width, h = size.height
        let center = CGPoint(x: planet.x * w, y: planet.y * h)
        let r = planet.radius * w
        let disc = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        // The ring's far half goes behind the planet, the near half in front.
        func ring(_ context: inout GraphicsContext, front: Bool) {
            context.drawLayer { layer in
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: .degrees(-16))
                layer.scaleBy(x: 1, y: 0.26)
                for (scale, width, opacity) in [(1.5, 11.0, 0.22), (1.72, 5.0, 0.3), (1.9, 2.0, 0.22)] as [(CGFloat, CGFloat, Double)] {
                    var arc = Path()
                    arc.addArc(center: .zero, radius: r * scale, startAngle: .degrees(front ? 0 : 180), endAngle: .degrees(front ? 180 : 360), clockwise: false)
                    layer.stroke(arc, with: .color(Theme.Palette.neon.opacity(opacity)), lineWidth: width)
                }
            }
        }
        if planet.ring { ring(&context, front: false) }

        // Atmosphere first, so the disc sits inside the glow.
        context.fill(
            Path(ellipseIn: disc.insetBy(dx: -r * 0.2, dy: -r * 0.2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Theme.Palette.neon.opacity(0), location: 0.8),
                    .init(color: Theme.Palette.neon.opacity(0.32), location: 0.86),
                    .init(color: Theme.Palette.glow.opacity(0), location: 1),
                ]),
                center: center,
                startRadius: 0,
                endRadius: r * 1.2
            )
        )
        context.fill(
            Path(ellipseIn: disc),
            with: .radialGradient(
                Gradient(colors: [Color(hex: 0x4A6AD0), Color(hex: 0x1F3278), Color(hex: 0x0A1238), Color(hex: 0x040716)]),
                center: CGPoint(x: center.x - r * 0.4, y: center.y + r * 0.35),
                startRadius: 0,
                endRadius: r * 1.5
            )
        )
        // Cloud bands, clipped to the disc.
        context.drawLayer { layer in
            layer.clip(to: Path(ellipseIn: disc))
            for (offset, thickness, opacity) in [(-0.45, 0.1, 0.1), (-0.1, 0.16, 0.08), (0.3, 0.09, 0.1), (0.58, 0.07, 0.07)] as [(CGFloat, CGFloat, Double)] {
                let band = CGRect(x: center.x - r, y: center.y + offset * r - thickness * r / 2, width: r * 2, height: thickness * r)
                layer.fill(Path(band), with: .color(Color.white.opacity(opacity)))
            }
            // Night side.
            layer.fill(
                Path(disc),
                with: .linearGradient(
                    Gradient(colors: [.clear, Color.black.opacity(0.6)]),
                    startPoint: CGPoint(x: center.x - r, y: center.y + r * 0.6),
                    endPoint: CGPoint(x: center.x + r * 0.9, y: center.y - r * 0.5)
                )
            )
        }
        if planet.ring { ring(&context, front: true) }
    }

    /// A perspective floor: lines fanning from the horizon, and rungs that slide toward you.
    private func drawGrid(_ context: inout GraphicsContext, horizon: CGFloat, color: Color, size: CGSize) {
        let w = size.width, h = size.height
        let floorHeight = h - horizon
        guard floorHeight > 8 else { return }
        let vanish = CGPoint(x: w / 2, y: horizon)

        context.fill(
            Path(CGRect(x: 0, y: horizon, width: w, height: floorHeight)),
            with: .linearGradient(
                Gradient(colors: [Theme.Palette.backgroundTop.opacity(0.1), Theme.Palette.backgroundTop.opacity(0.75)]),
                startPoint: CGPoint(x: 0, y: horizon),
                endPoint: CGPoint(x: 0, y: h)
            )
        )
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: horizon, width: w, height: floorHeight)))
            for index in -14 ... 14 {
                var line = Path()
                line.move(to: vanish)
                line.addLine(to: CGPoint(x: w / 2 + CGFloat(index) * w * 0.17, y: h))
                let fade = 1 - abs(Double(index)) / 16
                layer.stroke(
                    line,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.0), color.opacity(0.4 * fade)]),
                        startPoint: vanish,
                        endPoint: CGPoint(x: w / 2 + CGFloat(index) * w * 0.17, y: h)
                    ),
                    lineWidth: 0.9
                )
            }
            let rungs = 9
            let scroll = (time * 0.12).truncatingRemainder(dividingBy: 1)
            for rung in 0 ..< rungs {
                let depth = (Double(rung) + scroll) / Double(rungs)
                let y = horizon + floorHeight * CGFloat(pow(depth, 2.2))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: w, y: y))
                layer.stroke(line, with: .color(color.opacity(0.08 + 0.34 * depth)), lineWidth: 0.7 + CGFloat(depth) * 0.8)
            }
        }
        // The glowing line where the floor meets the sky.
        context.fill(
            Path(CGRect(x: 0, y: horizon - h * 0.05, width: w, height: h * 0.1)),
            with: .linearGradient(
                Gradient(colors: [color.opacity(0), color.opacity(0.32), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: horizon - h * 0.05),
                endPoint: CGPoint(x: 0, y: horizon + h * 0.05)
            )
        )
        var edge = Path()
        edge.move(to: CGPoint(x: 0, y: horizon))
        edge.addLine(to: CGPoint(x: w, y: horizon))
        context.stroke(
            edge,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0), color.opacity(0.9), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: horizon),
                endPoint: CGPoint(x: w, y: horizon)
            ),
            lineWidth: 1.2
        )
    }

    // MARK: Stars

    private struct Star {
        var x, y, radius: CGFloat
        var opacity: Double
        var color: Color
        var twinkles: Bool
        var sparkle: Bool
        var phase, speed, drift: Double
    }

    /// The same sky every time: a seeded generator, so a screen never reshuffles its stars.
    private static let stars: [Star] = {
        var generator = SeededRandom(seed: 2026)
        let tints: [Color] = [.white, .white, .white, Theme.Palette.neon, Color(hex: 0xB9A8FF), Color(hex: 0xFFE3B8)]
        return (0 ..< 170).map { index in
            let layer = index % 3
            let big = Double.random(in: 0 ... 1, using: &generator) > 0.93
            return Star(
                x: .random(in: 0 ... 1, using: &generator),
                y: .random(in: 0 ... 1, using: &generator),
                radius: [0.5, 0.8, 1.15][layer] + (big ? 0.5 : 0),
                opacity: [0.35, 0.6, 0.9][layer] * .random(in: 0.7 ... 1, using: &generator),
                color: tints.randomElement(using: &generator) ?? .white,
                twinkles: Double.random(in: 0 ... 1, using: &generator) < 0.4,
                sparkle: big,
                phase: .random(in: 0 ... 6.28, using: &generator),
                speed: .random(in: 0.8 ... 2.4, using: &generator),
                drift: [0.0005, 0.0011, 0.0022][layer]
            )
        }
    }()
}

/// A tiny deterministic generator (SplitMix64), so the backdrop is the same on every launch.
struct SeededRandom: RandomNumberGenerator {
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
