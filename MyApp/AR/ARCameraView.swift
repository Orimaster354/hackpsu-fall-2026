import ARKit
import RealityKit
import SwiftUI

/// Live camera feed driven by an existing `ARSession`. It never configures or runs the session itself.
struct ARCameraView: UIViewRepresentable {
    let tracking: ARTrackingSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = tracking.session
        // ARView may replace the session delegate on assignment; take it back.
        tracking.session.delegate = tracking
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
