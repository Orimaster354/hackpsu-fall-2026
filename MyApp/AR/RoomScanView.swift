import ARKit
import SwiftUI

/// The host's room scan screen (docs/ar-capture.md): perimeter walk, vantage tile, 360 degree sweep, world map.
/// Presented from `ContentView` through the lobby's "Scan room" button. Owns its AR session for the whole scan.
struct RoomScanView: View {
    @State private var tracking: ARTrackingSession
    @State private var flow: RoomScanFlow
    private let gameSession: GameSession
    @State private var confirmClose = false
    @Environment(\.dismiss) private var dismiss

    init(client: GameClient, session: GameSession) {
        let tracking = ARTrackingSession()
        _tracking = State(initialValue: tracking)
        _flow = State(initialValue: RoomScanFlow(backend: LiveScanBackend(tracking: tracking, client: client, session: session)))
        gameSession = session
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ARCameraView(tracking: tracking)
                .frame(height: flow.step == .sweeping ? 200 : 260)
                .clipped()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    banners
                    content
                }
                .padding()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            tracking.frameHandler = { [flow] frame in
                flow.handle(FrameInput(frame: frame, includePixelBuffer: flow.wantsPixelBuffer))
            }
            tracking.start()
        }
        .onDisappear {
            // Breaks the tracking -> closure -> flow -> backend -> tracking cycle.
            tracking.frameHandler = nil
            flow.cancel()
            tracking.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: tracking.interruptionCount) { _, _ in flow.sessionInterrupted() }
        .confirmationDialog("Leave the scan?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Leave and discard", role: .destructive) { dismiss() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The walk and sweep are lost, and you will need to scan again.")
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button(flow.step == .done ? "Done" : "Close") {
                if flow.step == .idle || flow.step == .done { dismiss() } else { confirmClose = true }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(tracking.quality == .normal ? Color.green : (tracking.quality == .notAvailable ? .red : .orange))
                    .frame(width: 10, height: 10)
                Text("Tracking: \(tracking.quality.label)").font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    @ViewBuilder private var banners: some View {
        if let error = tracking.lastError { banner(error, .red) }
        if tracking.isInterrupted { banner("The camera was interrupted. Return to the app and keep it open.", .orange) }
        if let message = flow.message { banner(message, .orange) }
        if !tracking.quality.isReliable, tracking.isRunning, flow.step != .idle, flow.step != .done {
            banner("\(tracking.quality.hint) Nothing is recorded until tracking is Normal.", .yellow)
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .idle: idle
        case .perimeter: perimeter
        case .uploadingPerimeter: busy(flow.detail, note: "Stay where you are.")
        case .pickingVantage, .walkingToVantage: vantage
        case .sweeping: sweeping
        case .uploadingSweep:
            busy(flow.detail, note: "Keep the phone pointed at the room. The server is finding the notes, which can take a while.")
            reportView
        case .savingMap: savingMap
        case .done: done
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan the room").font(.title2.bold())
            step(1, "Stick 6 to 8 bright yellow notes (7.5 cm or bigger) on the walls at chest height, at least 2 m apart.")
            step(2, "Walk once around the room edge, 0.3 to 0.5 m from the walls, and finish where you started (30 to 60 s).")
            step(3, "Pick a tile near the middle, stand on it, and turn slowly through a full circle (about 30 s).")
            Text("Keep the app open and the camera uncovered the whole time. If it is interrupted, the scan starts over.")
                .font(.footnote).foregroundStyle(.secondary)
            if !tracking.isRunning {
                Button("Restart camera") { tracking.start() }.buttonStyle(.bordered)
            }
            Button { flow.startPerimeter() } label: { Text("Start perimeter walk").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .disabled(!flow.canStartPerimeter)
            if !flow.canStartPerimeter {
                Text(tracking.isRunning ? "Waiting for tracking to be Normal. \(tracking.quality.hint)" : "The camera is not running.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var perimeter: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(flow.perimeterClosed ? "Walk recorded" : "Walking the perimeter").font(.title2.bold())
            HStack(alignment: .firstTextBaseline) {
                Text(clock(flow.perimeterElapsed)).font(.system(size: 44, weight: .bold, design: .monospaced))
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(flow.perimeterSamples) poses").monospacedDigit()
                    Text(String(format: "%.1f m walked", flow.perimeterPath)).monospacedDigit()
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            if !flow.perimeterClosed {
                if let gap = flow.perimeterGap, flow.perimeterElapsed > 5 {
                    let closed = gap <= PerimeterRecorder.closeGap
                    Label(String(format: "%.2f m from your start%@", gap, closed ? " · you can finish" : " · walk back to the start"),
                          systemImage: closed ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                        .foregroundStyle(closed ? .green : .orange)
                }
                Text("Stay close to the walls (0.3 to 0.5 m) and keep walking at a normal pace. Aim for 30 to 60 seconds, then return to where you started.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { flow.finishPerimeter() } label: { Text("Done, I'm back at the start").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.canFinishPerimeter)
                Button("Start over", role: .destructive) { flow.restartPerimeter() }.buttonStyle(.bordered)
            } else {
                Button { flow.finishPerimeter() } label: { Text("Upload again").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button("Walk again", role: .destructive) { flow.restartPerimeter() }.buttonStyle(.bordered)
            }
        }
    }

    private var vantage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(flow.step == .pickingVantage ? "Choose where to stand" : "Walk to the dashed tile").font(.title2.bold())
            Text(flow.step == .pickingVantage
                 ? "The suggested tile is near the middle. Tap another tile if you prefer. The notes should be within about 4 m of it."
                 : "The ring with a dot is you. Stand so the ring sits on the dashed tile, then start the sweep.")
                .font(.footnote).foregroundStyle(.secondary)
            if let grid = flow.grid {
                RoomMapView(grid: grid, stations: gameSession.stations, myTile: flow.liveTile, pendingTile: flow.chosenTile,
                            myInitial: "You", onTap: { flow.choose($0) })
                    .frame(maxWidth: .infinity)
            }
            if let tile = flow.liveTile, let target = flow.chosenTile {
                Label(tile == target ? "You are on the chosen tile" : "You are on tile \(tile.x + 1), \(tile.y + 1); target is \(target.x + 1), \(target.y + 1)",
                      systemImage: tile == target ? "checkmark.circle.fill" : "figure.walk")
                    .foregroundStyle(tile == target ? .green : .primary)
            } else {
                Label("You are outside the mapped room", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if flow.step == .pickingVantage {
                Button { flow.confirmVantage() } label: { Text("Walk to this tile").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            } else if flow.hasPendingSweep {
                Button { flow.retrySweepUpload() } label: { Text("Upload the sweep again").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button("Turn again", role: .destructive) { flow.redoSweep() }.buttonStyle(.bordered)
            } else {
                Button { flow.startSweep() } label: { Text("Start sweep").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.canStartSweep)
                Button("Pick another tile") { flow.changeVantage() }.buttonStyle(.bordered)
            }
            if flow.step == .walkingToVantage, !flow.hasPendingSweep, !flow.canStartSweep {
                Text("Start unlocks when tracking is Normal and you are on the dashed tile.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var sweeping: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 14)
                Circle().trim(from: 0, to: flow.sweepProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack {
                    Text("\(Int(flow.sweepDegrees))°").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("of 360°").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            HStack {
                Text("\(flow.sweepFrameCount) frames").monospacedDigit()
                Spacer()
                Text(String(format: "%.0f s of %.0f s", flow.sweepElapsed, SweepSampler.timeLimit)).monospacedDigit()
            }
            .font(.callout)
            turnRateLabel
            if flow.sweepDrifted { banner("Stay on your tile. You have moved more than 1 m.", .orange) }
            Text("Hold the phone at chest height, facing the walls, and turn slowly and steadily: about 10 to 12 degrees per second, one full circle in about 30 seconds.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Cancel sweep", role: .destructive) { flow.cancelSweep() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var turnRateLabel: some View {
        if let rate = flow.sweepTurnRate {
            let tooFast = rate > SweepSampler.maxTurnRate
            let color: Color = tooFast ? .red : (rate < 6 ? .yellow : .green)
            Label(String(format: "Turning %.0f°/s%@", rate, tooFast ? " · too fast, frames are skipped" : (rate < 6 ? " · a little faster" : " · good")),
                  systemImage: tooFast ? "exclamationmark.triangle.fill" : "gauge.medium")
                .foregroundStyle(color)
        } else {
            Label("Start turning slowly", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
        }
    }

    private var savingMap: some View {
        VStack(alignment: .leading, spacing: 14) {
            if flow.mapFailed {
                Text("The world map was not saved").font(.title2.bold())
                Text("The sweep is already uploaded. Keep the phone pointed at the room and try again.").font(.footnote).foregroundStyle(.secondary)
                Button { flow.retryMap() } label: { Text("Try again").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            } else {
                busy(flow.mapNote, note: "Slowly look around the room so ARKit can finish mapping it. Do not leave the app.")
            }
            reportView
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Scan uploaded", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(.green)
            Text("Close this screen and review the stations the server placed. Move or add stations on the edge tiles, then confirm.")
                .font(.footnote).foregroundStyle(.secondary)
            reportView
            Button { dismiss() } label: { Text("Back to the lobby").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var reportView: some View {
        if !flow.report.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Capture report").font(.headline)
                ForEach(flow.report) { line in
                    HStack(alignment: .top) {
                        Text(line.label).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(line.value).multilineTextAlignment(.trailing).foregroundStyle(line.warn ? Color.orange : Color.primary)
                    }
                    .font(.footnote)
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Pieces

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.footnote.bold()).frame(width: 22, height: 22).background(Color.white.opacity(0.15), in: Circle())
            Text(text).font(.callout)
        }
    }

    private func busy(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            Text(note).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text).font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
