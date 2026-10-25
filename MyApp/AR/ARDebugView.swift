import SwiftUI

/// AR-owned integration harness. Production lobby/map/manual UI remains with B.
struct ARDebugView: View {
    @State private var tracking = ARTrackingSession()
    @State private var serverAddress = ""
    @State private var roomCode = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ARCameraView(tracking: tracking).frame(height: 240).clipped()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    qualityBadge
                    if let error = tracking.lastError { banner(error, color: .red) }
                    if tracking.isInterrupted { banner("Session interrupted. Return to the scanned area.", color: .orange) }
                    capturePanel
                    serverPanel
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in positionPanel }
                    Button("Reset tracking and discard capture", systemImage: "arrow.counterclockwise") { tracking.reset() }
                        .buttonStyle(.bordered)
                        .disabled(tracking.isBusy)
                    Text("Reset creates a new coordinate frame. Never reset between overview and edge walk. Reset count: \(tracking.resetCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; tracking.start() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; tracking.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { tracking.start() }
            if phase == .background { tracking.pause() }
        }
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Host capture · two passes").font(.headline)
            Text("Use the same uninterrupted session for both passes. The server builds the room and grid; this app records only.")
                .font(.footnote).foregroundStyle(.secondary)
            switch tracking.captureStage {
            case .overviewReady:
                Text("1 · Overview: walk through the room and show every object. Aim for 30–60 seconds.")
                Button("Record overview") { tracking.startPass(.overview) }
                    .buttonStyle(.borderedProminent).disabled(tracking.reliablePosition == nil)
            case .overviewRecording, .edgeRecording:
                Text(tracking.captureStage == .overviewRecording ? "Recording overview" : "Recording edge walk")
                    .foregroundStyle(.red).font(.headline)
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let elapsed = ProcessInfo.processInfo.systemUptime - (tracking.captureStartedAt ?? ProcessInfo.processInfo.systemUptime)
                    Text("\(Int(max(0, elapsed))) s · aim for 30–60 s").monospacedDigit()
                }
                if tracking.captureStage == .edgeRecording {
                    Text("Stay about 0.5 m from the walls, show the wall/floor line, and return to your starting point.")
                }
                Button("Finish pass") { tracking.finishPass() }.buttonStyle(.borderedProminent)
                Button("Cancel both passes", role: .destructive) { tracking.cancelCapture() }
            case .overviewSaving, .edgeSaving:
                ProgressView("Finishing video and pose log…")
            case .edgeReady:
                Text("2 · Edge walk: walk once around the room, about 0.5 m from the walls. Show the walls and floor line. Close the loop at your start point. Aim for 30–60 seconds.")
                Button("Record edge walk") { tracking.startPass(.edge) }
                    .buttonStyle(.borderedProminent).disabled(tracking.reliablePosition == nil)
            case .mapReady:
                Text("Both passes saved. Keep looking around until tracking is healthy, then save the map.")
                Button("Retry world-map save") { tracking.retrySaveMap() }
                    .disabled(tracking.reliablePosition == nil)
            case .mapSaving:
                ProgressView("Saving AR world map…")
            case .ready:
                Text("Both passes and world map are ready to upload.").foregroundStyle(.green)
            case .uploading:
                ProgressView(tracking.uploadStatus)
            case .uploaded:
                Text(tracking.uploadStatus).foregroundStyle(.green)
            }
            if let artifact = tracking.overviewArtifact { artifactRow("Overview", artifact) }
            if let artifact = tracking.edgeArtifact { artifactRow("Edge walk", artifact) }
            if let map = tracking.mapURL { ShareLink("Export world map", item: map) }
            if let seconds = tracking.uploadSeconds {
                Text(String(format: "File uploads: %.1f s · target under 30 s on hotspot", seconds))
                    .font(.caption).monospacedDigit()
            }
        }
        .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func artifactRow(_ title: String, _ artifact: CaptureArtifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%@: %.1f s · %d poses", title, artifact.duration, artifact.poseCount))
                .font(.caption).monospacedDigit()
            HStack {
                ShareLink("Video", item: artifact.videoURL)
                ShareLink("Poses", item: artifact.posesURL)
                ShareLink("Intrinsics", item: artifact.intrinsicsURL)
            }.font(.caption)
        }
    }

    private var serverPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backend / joiner test").font(.headline)
            TextField("http://laptop-ip:8080", text: $serverAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Four-letter room code", text: $roomCode)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Upload both passes + map and process") {
                if let url = URL(string: serverAddress) { tracking.uploadCapture(baseURL: url, room: roomCode) }
            }
            .disabled(tracking.captureStage != .ready || !validServer)
            Button("Download world map and relocalize") {
                if let url = URL(string: serverAddress) { tracking.downloadMap(baseURL: url, room: roomCode) }
            }
            .disabled(tracking.isBusy || !validServer)
            if tracking.isDownloadingMap { ProgressView("Downloading world map…") }
            Text("Position source: \(tracking.positionMode.rawValue)").font(.caption)
            if tracking.positionMode == .relocalizing {
                Text("Point at the host's scanned area. Manual mode is offered after 20 seconds.").font(.footnote)
            }
            Button("Use manual tiles") { tracking.useManualMode() }
            if tracking.positionMode == .manual {
                Text("AR reports and icons are disabled. The UI owner must connect the manual tile picker.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("GameClient must supply the server grid/stations and connect the tile-report callback. This screen does not create rooms or simulate server setup.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var validServer: Bool {
        guard let url = URL(string: serverAddress) else { return false }
        return (try? ARCaptureTransport(baseURL: url, room: roomCode.uppercased()).endpoint(["map", roomCode.uppercased()])) != nil
    }

    private var qualityBadge: some View {
        let q = tracking.quality
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(q == .normal ? Color.green : .orange).frame(width: 14, height: 14)
                Text("Tracking: \(q.label)").font(.headline)
            }
            Text(q.hint).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var positionPanel: some View {
        let pose = tracking.pose
        let reliable = tracking.reliablePosition != nil
        return VStack(alignment: .leading, spacing: 6) {
            if !reliable { Text("POSITION NOT RELIABLE").font(.caption.bold()).foregroundStyle(.red) }
            axisRow("x", pose?.position.x)
            axisRow("y", pose?.position.y)
            axisRow("z", pose?.position.z)
            Text(pose.map { String(format: "Horizontal from origin: %.2f m", hypot($0.position.x, $0.position.z)) } ?? "Horizontal from origin: --")
                .font(.caption).monospacedDigit()
            let age = pose.map { ProcessInfo.processInfo.systemUptime - $0.timestamp }
            Text(age.map { String(format: "Last update %.1f s ago", $0) } ?? "No pose yet")
                .font(.caption).foregroundStyle((age ?? 99) > 0.5 ? .red : .secondary)
            if let tile = tracking.currentTile {
                Text("Tile: (\(tile.x), \(tile.y)) · report rate 3 Hz").font(.caption)
            } else { Text("No reportable tile. Server grid and localization are required.").font(.caption) }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .opacity(reliable ? 1 : 0.55)
    }

    private func axisRow(_ axis: String, _ value: Float?) -> some View {
        HStack {
            Text(axis).font(.title2.bold())
            Spacer()
            Text(value.map { String(format: "%+.2f m", $0) } ?? "--")
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview { ARDebugView() }
