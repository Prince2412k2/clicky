import AVFoundation
import FluidAudio
import Foundation

@MainActor
final class LocalKokoroTTSClient: NSObject, AVAudioPlayerDelegate {
    private let manager: KokoroAneManager
    private var audioPlayer: AVAudioPlayer?
    private var initializationTask: Task<Void, Error>?

    override init() {
        if #available(macOS 15.0, *) {
            manager = KokoroAneManager(
                defaultVoice: "af_heart",
                version: .v3
            )
        } else {
            manager = KokoroAneManager(defaultVoice: "af_heart")
        }
        super.init()
    }

    var isPlaying: Bool {
        audioPlayer?.isPlaying == true
    }

    func speakText(_ text: String) async throws {
        stopPlayback()
        try await prepareIfNeeded()
        try Task.checkCancellation()
        let wavData = try await manager.synthesize(text: text)
        try Task.checkCancellation()

        let audioPlayer = try AVAudioPlayer(data: wavData)
        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()
        guard audioPlayer.play() else {
            throw NSError(
                domain: "OpenClickyLocalTTS",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The generated local voice could not begin playback"]
            )
        }
        self.audioPlayer = audioPlayer
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func unloadModels() {
        stopPlayback()
        initializationTask?.cancel()
        initializationTask = nil
        Task { await manager.cleanup() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if audioPlayer === player {
            audioPlayer = nil
        }
    }

    private func prepareIfNeeded() async throws {
        if await manager.isAvailable() { return }
        if let initializationTask {
            return try await initializationTask.value
        }

        let initializationTask = Task { [manager] in
            try await manager.initialize(preloadVoices: Set(["af_heart"]))
        }
        self.initializationTask = initializationTask
        do {
            try await initializationTask.value
            self.initializationTask = nil
        } catch {
            self.initializationTask = nil
            throw error
        }
    }
}
