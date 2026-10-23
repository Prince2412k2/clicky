//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func prepare() async throws

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

extension BuddyTranscriptionProvider {
    func prepare() async throws {}
}

enum VoiceTranscriptionProvider: String, CaseIterable, Identifiable {
    case localParakeet = "parakeet"
    case appleSpeech = "apple"
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localParakeet: return "Parakeet Local"
        case .appleSpeech: return "Apple Speech"
        case .openAI: return "OpenAI API"
        }
    }
}

enum BuddyTranscriptionProviderFactory {
    private static let selectedProviderDefaultsKey = "selectedTranscriptionProvider"

    static func makeDefaultProvider() -> (VoiceTranscriptionProvider, any BuddyTranscriptionProvider) {
        let configuredProviderRawValue = UserDefaults.standard.string(forKey: selectedProviderDefaultsKey)
            ?? AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")
        let requestedProvider = configuredProviderRawValue
            .flatMap { VoiceTranscriptionProvider(rawValue: $0.lowercased()) }
            ?? .localParakeet
        let resolvedProvider = resolveProvider(requestedProvider)
        let provider = makeProvider(resolvedProvider)
        return (resolvedProvider, provider)
    }

    static func makeProvider(_ provider: VoiceTranscriptionProvider) -> any BuddyTranscriptionProvider {
        switch provider {
        case .localParakeet:
            return LocalParakeetTranscriptionProvider()
        case .appleSpeech:
            return AppleSpeechTranscriptionProvider()
        case .openAI:
            return OpenAIAudioTranscriptionProvider()
        }
    }

    static func saveSelectedProvider(_ provider: VoiceTranscriptionProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: selectedProviderDefaultsKey)
    }

    private static func resolveProvider(
        _ preferredProvider: VoiceTranscriptionProvider
    ) -> VoiceTranscriptionProvider {
        switch preferredProvider {
        case .localParakeet:
            return .localParakeet
        case .appleSpeech:
            return .appleSpeech
        case .openAI:
            let openAIProvider = OpenAIAudioTranscriptionProvider()
            if openAIProvider.isConfigured {
                return .openAI
            }
            return .appleSpeech
        }
    }
}
