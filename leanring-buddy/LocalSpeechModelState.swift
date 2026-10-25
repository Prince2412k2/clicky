import Combine
import Foundation

enum LocalModelPreparationState: Equatable {
    case notDownloaded
    case downloading(Double)
    case installing
    case downloaded
    case preparing
    case ready
    case failed(String)

    var displayText: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let progress): return "Downloading \(Int(progress * 100))%"
        case .installing: return "Downloading & compiling…"
        case .downloaded: return "Downloaded"
        case .preparing: return "Compiling…"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    var progress: Double? {
        if case .downloading(let progress) = self { return progress }
        return nil
    }
}

@MainActor
final class LocalSpeechModelState: ObservableObject {
    static let shared = LocalSpeechModelState()

    @Published var transcription: LocalModelPreparationState
    @Published var voice: LocalModelPreparationState

    private init() {
        transcription = Self.parakeetModelExists ? .downloaded : .notDownloaded
        voice = Self.kokoroModelExists ? .downloaded : .notDownloaded
    }

    func markTranscriptionDownloading(_ progress: Double) {
        transcription = .downloading(min(max(progress, 0), 1))
    }

    func markTranscriptionPreparing() {
        transcription = transcription == .notDownloaded ? .downloading(0) : .preparing
    }

    func markVoicePreparing() {
        voice = .installing
    }

    func markTranscriptionUnloaded() {
        transcription = Self.parakeetModelExists ? .downloaded : .notDownloaded
    }

    func markVoiceUnloaded() {
        voice = Self.kokoroModelExists ? .downloaded : .notDownloaded
    }

    private static var parakeetModelExists: Bool {
        applicationSupportDirectoryContainsFiles(
            relativePath: "FluidAudio/Models/parakeet-eou-streaming/parakeet-eou-streaming"
        )
            || applicationSupportDirectoryContainsFiles(
                relativePath: "FluidAudio/Models/parakeet-eou-streaming/320ms"
            )
    }

    private static var kokoroModelExists: Bool {
        let fluidAudioCacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
        return directoryContainsFiles(
            fluidAudioCacheDirectory.appendingPathComponent("kokoro-82m-coreml", isDirectory: true)
        )
            || directoryContainsFiles(
                fluidAudioCacheDirectory.appendingPathComponent("kokoro", isDirectory: true)
            )
    }

    private static func applicationSupportDirectoryContainsFiles(relativePath: String) -> Bool {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return false }
        return directoryContainsFiles(
            applicationSupportURL.appendingPathComponent(relativePath, isDirectory: true)
        )
    }

    private static func directoryContainsFiles(_ directoryURL: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return false }
        return !contents.isEmpty
    }
}
