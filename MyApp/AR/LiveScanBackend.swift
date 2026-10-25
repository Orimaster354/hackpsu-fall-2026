import ARKit

/// Connects `RoomScanFlow` to the real thing: ARKit for frames and the world map, `ScanClient` for the two scan
/// uploads, `GameClient` for the map upload, and the `GameSession` for the grid the server broadcasts.
@MainActor
final class LiveScanBackend: ScanBackend {
    let tracking: ARTrackingSession
    private let scanClient: ScanClient
    private let client: GameClient
    private let session: GameSession
    /// Shown to the host while the map is being prepared.
    private let mappingTimeout: Duration = .seconds(15)

    init(tracking: ARTrackingSession, client: GameClient, session: GameSession) {
        self.tracking = tracking
        self.client = client
        self.session = session
        scanClient = ScanClient(client: client)
    }

    var grid: MapGrid? { session.grid }

    func uploadPerimeter(_ poses: [PoseSample]) async throws -> PerimeterResult {
        try await scanClient.uploadPerimeter(poses: poses)
    }

    func uploadSweep(vantage: Tile, intrinsics: CameraIntrinsics, frames: [SweepFrame]) async throws -> SweepResult {
        try await scanClient.uploadSweep(vantage: vantage, intrinsics: intrinsics, frames: frames)
    }

    func captureWorldMap(progress: @escaping @MainActor (String) -> Void) async throws -> Data {
        // A map saved before ARKit has mapped enough of the room relocalizes badly. Give it a moment to
        // catch up, but never block the host forever: after the timeout the map is saved as it is.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: mappingTimeout)
        while tracking.worldMappingStatus != .mapped, tracking.worldMappingStatus != .extending, clock.now < deadline {
            progress("ARKit is still mapping the room (\(Self.describe(tracking.worldMappingStatus))). Slowly look around the room.")
            try await Task.sleep(for: .milliseconds(250))
        }
        progress("Saving the AR world map (\(Self.describe(tracking.worldMappingStatus)))…")
        return try await tracking.captureWorldMap()
    }

    func uploadWorldMap(_ data: Data) async throws {
        try await client.uploadMap(data)
    }

    /// Compares the documented pixel-to-ray math with ARKit's own projection of the same camera. If the two agree
    /// to a pixel or two, the pose convention and the intrinsics layout are what docs/ar-capture.md assumes.
    /// Informational only: it cannot see the JPEG, and its orientation argument is itself an assumption.
    func projectionSelfCheck() -> Double? {
        guard let frame = tracking.session.currentFrame else { return nil }
        let camera = frame.camera
        let k = camera.intrinsics
        let size = camera.imageResolution
        var worst = 0.0
        for depth in [1.5, 3.0, 5.0] as [Float] {
            for (a, b) in [(-0.4, -0.3), (0, 0), (0.4, 0.3), (-0.4, 0.3), (0.4, -0.3)] as [(Float, Float)] {
                // A point in camera space: right a*depth, up b*depth, straight ahead (-z) by depth.
                let local = SIMD4<Float>(a * depth, b * depth, -depth, 1)
                let world = camera.transform * local
                let expectedU = Double(k.columns.2.x) + Double(k.columns.0.x) * Double(local.x / -local.z)
                let expectedV = Double(k.columns.2.y) - Double(k.columns.1.y) * Double(local.y / -local.z)
                let arkit = camera.projectPoint(SIMD3(world.x, world.y, world.z), orientation: .landscapeRight, viewportSize: size)
                worst = max(worst, hypot(Double(arkit.x) - expectedU, Double(arkit.y) - expectedV))
            }
        }
        return worst
    }

    private static func describe(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: "not available"
        case .limited: "limited"
        case .extending: "extending"
        case .mapped: "mapped"
        @unknown default: "unknown"
        }
    }
}

extension FrameInput {
    /// Copies what the scan needs out of the frame. The pixel buffer is only included when asked for.
    init(frame: ARFrame, includePixelBuffer: Bool) {
        let camera = frame.camera
        sample = FrameSample(timestamp: frame.timestamp, transform: camera.transform, intrinsics: camera.intrinsics,
                             imageWidth: Double(camera.imageResolution.width), imageHeight: Double(camera.imageResolution.height),
                             isTracking: camera.trackingState == .normal)
        pixelBuffer = includePixelBuffer ? frame.capturedImage : nil
    }
}
