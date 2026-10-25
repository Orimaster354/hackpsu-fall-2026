import AVFoundation
import SwiftUI

/// The live back camera, drawn behind a task so it plays out in the room. It is only a picture:
/// no tracking, no anchors. If the camera cannot run (simulator, permission denied, or the
/// camera usage description missing from the target) `status` becomes `.unavailable` and the
/// task keeps its plain backdrop.
@Observable
final class CameraFeed {
    enum Status { case starting, running, unavailable }

    private(set) var status = Status.starting
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "task.camera")
    private var configured = false

    func start() async {
        // Asking for access without this Info.plist key crashes the app, so check for it first.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            status = .unavailable
            return
        }
        var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard allowed, configure() else {
            status = .unavailable
            return
        }
        let session = session
        queue.async { session.startRunning() }
        status = .running
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }

    private func configure() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        session.commitConfiguration()
        configured = true
        return true
    }
}

/// Fills its frame with the camera feed.
struct CameraBackdrop: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
