import ARKit
import Combine
import RealityKit
import SwiftUI

/// Puts the task in the room as a 3D station prop, drawn on the AR session's one shared view (the phone has one
/// camera and only one session may own it, so this never starts, pauses or replaces a session or a view).
///
/// The prop is placed once, in front of the player and about a meter below the phone, and stays
/// put in the room. If the player turns away from it it is placed again in front of them. The
/// flat tasks (tilt, pattern) put it right under the phone, because the camera then looks down.
///
/// In AR the prop is the task. The phone's motion drives it (the ball rolls on the tray, the knob turns, the nail
/// sinks), and `telemetry.aimed` says whether the camera is pointed at it, so the task screen can hold progress
/// until the player looks at what they are working on.
struct TaskARBackdrop: UIViewRepresentable {
    /// The session's shared view (`ARTrackingSession.arView`). Never a new one: a throwaway ARView pauses the
    /// session when it goes away, which is what used to lose tracking after every task.
    let arView: ARView
    let task: TaskKind
    let telemetry: TaskTelemetry
    var inFrontOfCamera = false

    func makeCoordinator() -> Coordinator {
        Coordinator(task: task, telemetry: telemetry, inFrontOfCamera: inFrontOfCamera)
    }

    func makeUIView(context: Context) -> ARView {
        let view = arView
        view.scene.addAnchor(context.coordinator.anchor)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: Scene

    final class Coordinator {
        let anchor = AnchorEntity(world: .zero)
        private let task: TaskKind
        private let telemetry: TaskTelemetry
        private let inFrontOfCamera: Bool
        private weak var view: ARView?
        private var updates: Cancellable?

        private let prop = Entity()
        private let top = Entity()
        private let bar = ModelEntity()
        private var accent: [ModelEntity] = []
        private let ball = ModelEntity()
        private let knob = Entity()
        private let nail = Entity()
        private let hammerArm = Entity()
        private var lastStrike = 0

        private var placed = false
        private var outOfViewSince: Date?
        private var shownColor: UIColor?
        private var lastJolt = 0
        private var pulse: Float = 0

        /// Nail height (its center) when fully out, and how far it sinks over a full task.
        private static let nailOutY: Float = 0.29
        private static let nailTravel: Float = 0.174
        /// Hammer tilt in radians when raised, and how far a strike swings it down.
        private static let hammerRaised: Float = 0.7
        private static let hammerSwing: Float = 1.0

        private static let idle = UIColor.systemBlue
        private static let good = UIColor.systemGreen
        private static let failed = UIColor.systemRed

        init(task: TaskKind, telemetry: TaskTelemetry, inFrontOfCamera: Bool) {
            self.inFrontOfCamera = inFrontOfCamera
            self.task = task
            self.telemetry = telemetry
            build()
            prop.isEnabled = false
            anchor.addChild(prop)
        }

        func attach(to view: ARView) {
            self.view = view
            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }

        func detach() {
            updates?.cancel()
            updates = nil
            anchor.removeFromParent()
        }

        // MARK: Building the prop
        // Local axes: +x is the player's right, +y up, +z toward the player.

        private func build() {
            let pedestal = ModelEntity(
                mesh: .generateCylinder(height: 0.6, radius: 0.16),
                materials: [SimpleMaterial(color: .darkGray, roughness: 0.5, isMetallic: true)]
            )
            pedestal.position.y = 0.3
            prop.addChild(pedestal)

            top.position.y = 0.6
            prop.addChild(top)

            switch task {
            case .shake:
                top.addChild(accented(.generateBox(size: 0.2, cornerRadius: 0.02), y: 0.12))
            case .tilt, .gesture:
                top.addChild(accented(.generateCylinder(height: 0.02, radius: 0.22), y: 0.01))
                ball.model = ModelComponent(mesh: .generateSphere(radius: 0.035), materials: [UnlitMaterial(color: .white)])
                ball.position.y = 0.055
                top.addChild(ball)
            case .dial:
                // A knob facing the player: a disc on a horizontal axis with a marker on its rim.
                let disc = accented(.generateCylinder(height: 0.06, radius: 0.16), y: 0.22)
                disc.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                let marker = ModelEntity(mesh: .generateBox(size: [0.03, 0.08, 0.03]), materials: [UnlitMaterial(color: .white)])
                marker.position = [0, 0.12, 0.05]
                knob.position.y = 0.22
                knob.addChild(disc)
                knob.addChild(marker)
                disc.position = .zero
                top.addChild(knob)
            case .hold:
                top.addChild(accented(.generateSphere(radius: 0.1), y: 0.16))
            case .hammer:
                // A block of wood with a nail standing in it, and a hammer beside it. The block top is at y = 0.2.
                top.addChild(accented(.generateBox(size: [0.3, 0.2, 0.3], cornerRadius: 0.02), y: 0.1))
                nail.position = [0, Self.nailOutY, 0]
                nail.addChild(ModelEntity(mesh: .generateCylinder(height: 0.18, radius: 0.012), materials: [UnlitMaterial(color: .lightGray)]))
                let nailHead = ModelEntity(mesh: .generateCylinder(height: 0.012, radius: 0.04), materials: [UnlitMaterial(color: .white)])
                nailHead.position.y = 0.09
                nail.addChild(nailHead)
                top.addChild(nail)
                let handle = ModelEntity(mesh: .generateBox(size: [0.025, 0.24, 0.025]), materials: [UnlitMaterial(color: .brown)])
                handle.position.y = 0.12
                let hammerHead = ModelEntity(mesh: .generateBox(size: [0.11, 0.05, 0.05]), materials: [UnlitMaterial(color: .white)])
                hammerHead.position = [-0.04, 0.24, 0]
                hammerArm.position = [0.2, 0.3, 0]
                hammerArm.addChild(handle)
                hammerArm.addChild(hammerHead)
                hammerArm.orientation = simd_quatf(angle: Self.hammerRaised, axis: [0, 0, 1])
                top.addChild(hammerArm)
            }

            bar.model = ModelComponent(mesh: .generateBox(size: [0.05, 1, 0.05]), materials: [UnlitMaterial(color: Self.good)])
            bar.position = [0.3, 0, 0]
            bar.scale = [1, 0.001, 1]
            prop.addChild(bar)
        }

        private func accented(_ mesh: MeshResource, y: Float) -> ModelEntity {
            let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: Self.idle)])
            entity.position.y = y
            accent.append(entity)
            return entity
        }

        // MARK: Per frame

        private func tick() {
            guard let view, let frame = view.session.currentFrame else { return }
            // Without normal tracking the prop cannot be judged, so nothing is held back for it.
            guard frame.camera.trackingState == .normal else {
                telemetry.aimed = true
                return
            }
            let t = frame.camera.transform
            let camera = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let look = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let heading = SIMD3<Float>(look.x, 0, look.z)
            let headingLength = simd_length(heading)
            let forward = headingLength > 0.3 ? heading / headingLength : SIMD3<Float>(0, 0, -1)

            if telemetry.recenterRequested {
                telemetry.recenterRequested = false
                if inFrontOfCamera || headingLength > 0.3 { place(camera: camera, heading: forward, look: look) }
            }
            if !placed {
                guard inFrontOfCamera || headingLength > 0.3 else { return }
                place(camera: camera, heading: forward, look: look)
            } else if inFrontOfCamera || headingLength > 0.5 {
                recenterIfOutOfView(camera: camera, look: look, heading: forward)
            }
            updateAim(camera: camera, look: look)
            animate()
        }

        private func place(camera: SIMD3<Float>, heading: SIMD3<Float>, look: SIMD3<Float>) {
            let flat = task == .tilt || task == .gesture
            var position = camera + heading * (flat ? 0.1 : 1.1)
            position.y = camera.y - 1.0
            if inFrontOfCamera {
                // The working surface is 0.6–0.9 m above the prop base: put that surface on the view ray.
                position = TaskPropPlacement.base(camera: camera, look: look)
            }
            // Turns the prop's -z axis to the player's heading, so +x is their right.
            let yaw = atan2(-heading.x, -heading.z)
            anchor.position = position
            anchor.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            prop.isEnabled = true
            placed = true
            outOfViewSince = nil
        }

        /// True while the prop is roughly where the camera points (within about 60 degrees of the view direction).
        private func updateAim(camera: SIMD3<Float>, look: SIMD3<Float>) {
            guard placed else {
                telemetry.aimed = true
                return
            }
            let toProp = simd_normalize(anchor.position + [0, 0.5, 0] - camera)
            telemetry.aimed = simd_dot(toProp, simd_normalize(look)) > 0.5
        }

        private func recenterIfOutOfView(camera: SIMD3<Float>, look: SIMD3<Float>, heading: SIMD3<Float>) {
            let toProp = simd_normalize(anchor.position + [0, 0.5, 0] - camera)
            guard simd_dot(toProp, simd_normalize(look)) < 0.6 else {
                outOfViewSince = nil
                return
            }
            let since = outOfViewSince ?? Date()
            outOfViewSince = since
            if Date().timeIntervalSince(since) > 2 { place(camera: camera, heading: heading, look: look) }
        }

        private func animate() {
            let p = Float(max(0.001, min(1, telemetry.progress)))
            bar.scale.y = p
            bar.position.y = 0.5 * p

            let color: UIColor = switch telemetry.state {
            case .success: Self.good
            case .timedOut: Self.failed
            case .running: telemetry.good ? Self.good : Self.idle
            }
            if color != shownColor {
                shownColor = color
                for entity in accent { entity.model?.materials = [UnlitMaterial(color: color)] }
            }

            if telemetry.joltCount != lastJolt {
                lastJolt = telemetry.joltCount
                pulse = 1
            }
            if telemetry.strikeCount != lastStrike {
                lastStrike = telemetry.strikeCount
                pulse = 1
            }
            pulse = max(0, pulse - 0.08)

            switch task {
            case .shake:
                let shift = pulse * 0.06
                top.position.x = Float.random(in: -shift ... shift)
                top.position.z = Float.random(in: -shift ... shift)
                top.scale = SIMD3(repeating: 1 + pulse * 0.25)
            case .tilt, .gesture:
                let radius: Float = 0.19
                ball.position.x = Float(telemetry.ballX) * radius
                ball.position.z = Float(telemetry.ballY) * radius
            case .dial:
                knob.orientation = simd_quatf(angle: -Float(telemetry.dialAngle) * .pi / 180, axis: [0, 0, 1])
            case .hold:
                let swell = 1 + 0.4 * p
                top.scale = SIMD3(repeating: swell)
            case .hammer:
                // The nail sinks with progress; each strike snaps the hammer down and the block shudders.
                nail.position.y = Self.nailOutY - Self.nailTravel * p
                hammerArm.orientation = simd_quatf(angle: Self.hammerRaised - pulse * Self.hammerSwing, axis: [0, 0, 1])
                top.position.x = Float.random(in: -1 ... 1) * pulse * 0.01
            }

            if telemetry.state == .success {
                top.position.y = 0.6 + 0.05 * sin(Float(Date().timeIntervalSinceReferenceDate) * 6)
            }
        }
    }
}
