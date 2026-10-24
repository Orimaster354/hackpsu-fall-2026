import SwiftUI

/// Phase 1 test screen: camera feed, live position, tracking quality, errors and a reset button.
struct ARDebugView: View {
    @State private var tracking = ARTrackingSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ARCameraView(tracking: tracking)
                .frame(maxHeight: 260)
                .clipped()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    qualityBadge
                    if let error = tracking.lastError { banner(error, color: .red) }
                    if tracking.isInterrupted {
                        banner("Session interrupted (camera in use or app backgrounded).", color: .orange)
                    }
                    positionPanel
                    Button {
                        tracking.reset()
                    } label: {
                        Label("Reset tracking session", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Reset sets the origin to the phone's current position. Reset count: \(tracking.resetCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            tracking.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            tracking.pause()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !tracking.isRunning { tracking.start() }
        }
    }

    // MARK: Pieces

    private var qualityBadge: some View {
        let q = tracking.quality
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color(for: q)).frame(width: 14, height: 14)
                Text("Tracking: \(q.label)").font(.headline)
            }
            Text(q.hint).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var positionPanel: some View {
        let pose = tracking.pose
        let reliable = pose?.quality.isReliable ?? false
        return VStack(alignment: .leading, spacing: 6) {
            if !reliable {
                Text("POSITION NOT RELIABLE. Do not trust these numbers.")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
            axisRow("x", pose?.position.x)
            axisRow("y", pose?.position.y)
            axisRow("z", pose?.position.z)
            Divider()
            HStack {
                Text("Horizontal from origin")
                Spacer()
                Text(pose.map { String(format: "%.2f m", hypot($0.position.x, $0.position.z)) } ?? "--")
                    .monospacedDigit()
            }
            .font(.callout)
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let age = pose.map { ProcessInfo.processInfo.systemUptime - $0.timestamp }
                Text(age.map { String(format: "Last update %.1f s ago", $0) } ?? "No pose yet")
                    .font(.caption)
                    .foregroundStyle((age ?? 99) > 0.5 ? .red : .secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .opacity(reliable ? 1 : 0.55)
    }

    private func axisRow(_ axis: String, _ value: Float?) -> some View {
        HStack {
            Text(axis).font(.title2.bold()).frame(width: 28, alignment: .leading)
            Spacer()
            Text(value.map { String(format: "%+.2f m", $0) } ?? "--")
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(for q: TrackingQuality) -> Color {
        switch q {
        case .normal: .green
        case .notAvailable: .red
        default: .orange
        }
    }
}

#Preview {
    ARDebugView()
}
