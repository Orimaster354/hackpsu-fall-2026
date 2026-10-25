import ARKit
import RealityKit
import SwiftUI

/// Presentation input only. B/D translate Station fields; this is not a wire model.
nonisolated struct ARStationIcon: Equatable, Identifiable {
    enum Kind { case task, fix, emergency }
    let id: String
    let tileX, tileY: Int
    let kind: Kind
    var completed = false
}

struct ARCameraView: UIViewRepresentable {
    let tracking: ARTrackingSession

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        // The session's one shared view, never a new one: see ARTrackingSession.arView.
        let view = tracking.arView
        view.scene.addAnchor(context.coordinator.root)
        let root = context.coordinator.root
        // Hide stale overlays even if ARKit stops delivering frames without an error callback.
        context.coordinator.visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak tracking, weak root] _ in
            MainActor.assumeIsolated { root?.isEnabled = tracking?.iconsVisible ?? false }
        }
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        let snapshot = Coordinator.Snapshot(icons: tracking.stationIcons, grid: tracking.grid,
                                            visible: tracking.iconsVisible, lightsOut: tracking.lightsOut)
        guard snapshot != coordinator.snapshot else { return }
        coordinator.snapshot = snapshot
        coordinator.root.children.removeAll()
        coordinator.root.isEnabled = snapshot.visible
        guard snapshot.visible, let grid = snapshot.grid else { return }
        for icon in snapshot.icons {
            guard icon.kind != .fix || snapshot.lightsOut,
                  let position = grid.worldCenter(x: icon.tileX, y: icon.tileY, elevation: 0),
                  let entity = coordinator.makeIcon(icon) else { continue }
            let anchor = Entity()
            anchor.position = position
            anchor.components.set(BillboardComponent())
            anchor.addChild(entity)
            coordinator.root.addChild(anchor)
        }
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.visibilityTimer?.invalidate()
        coordinator.root.removeFromParent()
    }

    final class Coordinator {
        struct Snapshot: Equatable {
            let icons: [ARStationIcon]
            let grid: ServerGridTracking?
            let visible, lightsOut: Bool
        }
        let root = AnchorEntity(world: SIMD3<Float>.zero)
        var snapshot: Snapshot?
        var visibilityTimer: Timer?

        func makeIcon(_ icon: ARStationIcon) -> ModelEntity? {
            let size = CGSize(width: 512, height: 256)
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.black.withAlphaComponent(0.8).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 36).fill()
                if icon.kind == .fix {
                    UIImage(systemName: "wrench.fill")?.withTintColor(.yellow, renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: 160, y: 32, width: 192, height: 192))
                } else {
                    let text = icon.kind == .emergency ? "EMERGENCY" : "?"
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: icon.kind == .emergency ? 64 : 190, weight: .heavy),
                        .foregroundColor: icon.kind == .emergency ? UIColor.systemRed : UIColor.white
                    ]
                    let textSize = (text as NSString).size(withAttributes: attributes)
                    (text as NSString).draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                                       y: (size.height - textSize.height) / 2), withAttributes: attributes)
                }
            }
            guard let cgImage = image.cgImage,
                  let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: icon.kind == .task && icon.completed ? 0.25 : 1))
            let width: Float = icon.kind == .emergency ? 1 : 0.65
            return ModelEntity(mesh: .generatePlane(width: width, height: width / 2), materials: [material])
        }
    }
}
