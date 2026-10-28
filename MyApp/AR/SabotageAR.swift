import ARKit
import Combine
import RealityKit
import SwiftUI

/// The jammer and the meltdown in AR: the live camera in a card, with the fix station marked in the room and the
/// screen dressed for what is wrong. The jammer fills it with static and a glitching antenna marker; the meltdown
/// stands a pulsing red core on the fix tile under a red alarm glow. Lights out has its own view (`LightsOutARView`).
/// This draws on the tracking session's shared view and never starts, pauses or replaces the session.
struct SabotageARView: View {
    let arView: ARView
    let grid: MapGrid
    let fix: MapStation?
    let sabotage: SabotageState
    let tracking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            SabotageCamera(arView: arView, grid: grid, fix: fix, kind: sabotage.kind, tracking: tracking)
            switch sabotage.kind {
            case .jammer, .lights:
                StaticNoise(still: reduceMotion)
                    .allowsHitTesting(false)
            case .meltdown:
                MeltdownGlow(still: reduceMotion)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 6) {
                if sabotage.kind == .meltdown, let endsAt = sabotage.endsAt {
                    MeltdownCountdown(endsAt: endsAt)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Label(caption, systemImage: sabotage.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(sabotage.kind.tint)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sabotage.kind == .jammer
                            ? "Comms jammer camera. The antenna marks the fix station."
                            : "Meltdown camera. The red core marks the fix station.")
    }

    private var caption: String {
        if !tracking { return "Finding your place… Use the map to reach the fix station." }
        switch sabotage.kind {
        case .meltdown: return "Find the glowing core. Two of you must stabilize it at the same time."
        default: return "Find the antenna. Walk to its tile to retune the comms."
        }
    }
}

/// Television static: flickering specks, scan lines and a bar that jumps about. Repainted ten times a second.
private struct StaticNoise: View {
    let still: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.28)))
                for _ in 0 ..< (still ? 40 : 220) {
                    let x = CGFloat.random(in: 0 ..< size.width)
                    let y = CGFloat.random(in: 0 ..< size.height)
                    let rect = CGRect(x: x, y: y, width: CGFloat.random(in: 3 ... 22), height: CGFloat.random(in: 1 ... 3))
                    context.fill(Path(rect), with: .color(.white.opacity(Double.random(in: 0.05 ... 0.4))))
                }
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.3)))
                    y += 4
                }
                if !still {
                    let bar = CGRect(x: 0, y: CGFloat.random(in: 0 ..< size.height), width: size.width, height: 10)
                    context.fill(Path(bar), with: .color(Theme.Palette.neon.opacity(0.22)))
                }
            }
        }
    }
}

/// A red alarm glow around the edge that beats faster than a heart.
private struct MeltdownGlow: View {
    let still: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: still ? 1 : 1.0 / 30)) { timeline in
            let beat = still ? 0.6 : 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 6)
            RadialGradient(colors: [.clear, Theme.Palette.emergency.opacity(0.25 + 0.4 * beat)],
                           center: .center, startRadius: 60, endRadius: 220)
        }
    }
}

/// The camera, with the fix station marked in the room: an antenna for the jammer, a core for the meltdown.
private struct SabotageCamera: UIViewRepresentable {
    let arView: ARView
    let grid: MapGrid
    let fix: MapStation?
    let kind: SabotageKind
    let tracking: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        arView.scene.addAnchor(context.coordinator.root)
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        guard tracking, let fix, grid.contains(fix.tile) else {
            coordinator.clear()
            return
        }
        let center = grid.worldCenter(of: fix.tile)
        coordinator.show(kind: kind, at: SIMD3(Float(center.x), 0, Float(center.z)))
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        // Detach this overlay only. The tracking owner keeps the AR session running.
        coordinator.detach()
    }

    final class Coordinator {
        let root = AnchorEntity(world: SIMD3<Float>.zero)
        private var shown: (kind: SabotageKind, position: SIMD3<Float>)?
        private var pulsing: [Entity] = []
        private var updates: Cancellable?
        private var kind = SabotageKind.jammer

        func attach(to view: ARView) {
            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.pulse() }
            }
        }

        func detach() {
            updates?.cancel()
            updates = nil
            root.removeFromParent()
        }

        func clear() {
            guard shown != nil else { return }
            shown = nil
            pulsing = []
            root.children.removeAll()
        }

        func show(kind: SabotageKind, at position: SIMD3<Float>) {
            if let shown, shown.kind == kind, shown.position == position { return }
            clear()
            shown = (kind, position)
            self.kind = kind
            guard let marker = Self.marker(for: kind) else { return }
            // The sign always faces the player. Its post stands on the fix tile.
            let sign = Entity()
            sign.position = position + SIMD3(0, 1.1, 0)
            sign.components.set(BillboardComponent())
            sign.addChild(marker)
            root.addChild(sign)
            pulsing.append(marker)
            if kind == .meltdown {
                let core = ModelEntity(mesh: .generateSphere(radius: 0.2), materials: [UnlitMaterial(color: .systemRed)])
                core.position = position + SIMD3(0, 0.3, 0)
                root.addChild(core)
                pulsing.append(core)
            }
        }

        private func pulse() {
            guard !pulsing.isEmpty else { return }
            let t = Float(Date().timeIntervalSinceReferenceDate)
            // The meltdown beats fast and wide; the jammer flickers.
            let scale: Float = kind == .meltdown ? 1 + 0.3 * abs(sin(t * 6)) : 1 + 0.08 * sin(t * 13) * sin(t * 3)
            for entity in pulsing { entity.scale = SIMD3(repeating: scale) }
        }

        private static func marker(for kind: SabotageKind) -> ModelEntity? {
            let size = CGSize(width: 512, height: 256)
            let symbol = kind == .meltdown ? "flame.fill" : "antenna.radiowaves.left.and.right"
            let tint: UIColor = kind == .meltdown ? .systemRed : .cyan
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.black.withAlphaComponent(0.8).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 36).fill()
                UIImage(systemName: symbol)?.withTintColor(tint, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 160, y: 32, width: 192, height: 192))
            }
            guard let cgImage = image.cgImage,
                  let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            return ModelEntity(mesh: .generatePlane(width: 0.9, height: 0.45), materials: [material])
        }
    }
}
