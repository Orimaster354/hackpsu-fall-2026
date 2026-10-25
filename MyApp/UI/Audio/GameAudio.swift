import AVFoundation
import SwiftUI

extension EnvironmentValues {
    /// Optional so standalone task previews can still run without the game's audio owner.
    @Entry var gameAudio: GameAudio? = nil
}

/// Owns the game's music and one-shot cues for the lifetime of RootView, including its task sheets.
/// Uses the system Silent switch and never records audio or changes the camera's session.
@MainActor
final class GameAudio {
    enum Scene: Equatable {
        case lobby, gameplay, lightsOut, meeting

        fileprivate var fileName: String {
            switch self {
            case .lobby: "lobby_pre_post_game"
            case .gameplay, .meeting: "general_ost"
            case .lightsOut: "lights_out"
            }
        }

        fileprivate var volume: Float {
            switch self {
            case .lobby: 0.35
            case .gameplay: 0.4
            case .lightsOut: 0.45
            case .meeting: 0.12
            }
        }
    }

    enum Cue: String {
        case meeting = "bodyrep_meeting"
        case taskComplete = "task_comp"
        case taskFailed = "task_failed"
    }

    private var scene = Scene.lobby
    private var isActive = false
    private var isInterrupted = false
    private var resumeAllowed = true
    private var sessionIsActive = false
    private var music: AVAudioPlayer?
    private var musicFile: String?
    private var cue: AVAudioPlayer?
    private var cueFinish: Task<Void, Never>?
    private let notifications = AudioNotifications()

    init() {
        notifications.observe(AVAudioSession.interruptionNotification) { [weak self] notification in
            self?.interruption(notification)
        }
        notifications.observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            guard let self else { return }
            self.stopCue()
            self.music = nil
            self.musicFile = nil
            self.sessionIsActive = false
            self.resumeMusic()
        }
    }

    func setScene(_ scene: Scene) {
        self.scene = scene
        resumeMusic()
    }

    func setActive(_ active: Bool) {
        let returningToForeground = active && !isActive
        isActive = active
        if active {
            // Returning to the game is an explicit new playback opportunity, unless an interruption is ongoing.
            if returningToForeground, !isInterrupted { resumeAllowed = true }
            resumeMusic()
        } else {
            music?.pause()
            stopCue()
            if sessionIsActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                sessionIsActive = false
            }
        }
    }

    /// One cue channel keeps repeated inputs from piling up. The OST ducks until this clip finishes.
    func play(_ sound: Cue) {
        guard canPlay, activateSession(), let player = load(sound.rawValue) else { return }
        stopCue()
        cue = player
        player.volume = 1
        guard player.play() else { cue = nil; return }
        updateVolume()
        let duration = player.duration
        cueFinish = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.cue = nil
            self?.cueFinish = nil
            self?.updateVolume()
        }
    }

    private var canPlay: Bool {
        isActive && !isInterrupted && resumeAllowed
            && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
    }

    private func resumeMusic() {
        guard canPlay, activateSession() else { return }
        if musicFile != scene.fileName || music == nil {
            guard let next = load(scene.fileName) else { return }
            music?.stop()
            music = next
            musicFile = scene.fileName
            next.numberOfLoops = -1
            next.volume = 0
        }
        guard let music else { return }
        if !music.isPlaying { music.play() }
        updateVolume()
    }

    private func updateVolume() {
        music?.setVolume(scene.volume * (cue == nil ? 1 : 0.2), fadeDuration: 0.3)
    }

    private func stopCue() {
        cueFinish?.cancel()
        cueFinish = nil
        cue?.stop()
        cue = nil
        updateVolume()
    }

    private func activateSession() -> Bool {
        if sessionIsActive { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            sessionIsActive = true
            return true
        } catch {
            report("Audio session unavailable: \(error.localizedDescription)")
            return false
        }
    }

    private func load(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            report("Missing bundled audio: \(name).mp3")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            report("Could not load \(name).mp3: \(error.localizedDescription)")
            return nil
        }
    }

    private func interruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isInterrupted = true
            sessionIsActive = false
            music?.pause()
            stopCue()
        case .ended:
            isInterrupted = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            resumeAllowed = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            if resumeAllowed { resumeMusic() }
        @unknown default: break
        }
    }

    private func report(_ message: String) {
        #if DEBUG
        print("[GameAudio] \(message)")
        #endif
    }
}

/// Delivers notifications on the main queue and removes their tokens with the audio owner.
private final class AudioNotifications {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    func observe(_ name: Notification.Name, handler: @escaping @MainActor (Notification) -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated { handler(notification) }
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
