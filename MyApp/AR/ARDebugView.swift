import ARKit
import SwiftUI

/// AR-owned tracking harness: live camera, quality, position and a reset. Not part of the game. Open it with
/// the launch argument `-arDebug YES` on a Debug build (see ContentView). The room scan has its own screen,
/// `RoomScanView`, reached from the lobby's "Scan room" button.
struct ARDebugView: View {
    @State private var tracking = ARTrackingSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ARCameraView(tracking: tracking).frame(height: 240).clipped()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    qualityBadge
                    if let error = tracking.lastError { banner(error, color: .red) }
                    if tracking.isInterrupted { banner("Session interrupted. Return to the scanned area.", color: .orange) }
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in positionPanel }
                    Button("Reset tracking (new origin)", systemImage: "arrow.counterclockwise") { tracking.reset() }
                        .buttonStyle(.bordered)
                    Text("Reset creates a new coordinate frame. Never reset during a room scan. Reset count: \(tracking.resetCount). Mapping: \(describe(tracking.worldMappingStatus))")
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

    private func describe(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: "not available"
        case .limited: "limited"
        case .extending: "extending"
        case .mapped: "mapped"
        @unknown default: "unknown"
        }
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
