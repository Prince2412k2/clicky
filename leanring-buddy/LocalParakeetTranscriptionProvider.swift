import AVFoundation
import FluidAudio
import Foundation

struct LocalParakeetTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LocalParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet Local"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    static func unloadModels() {
        Task { await LocalParakeetModelPool.shared.cleanup() }
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let manager = try await LocalParakeetModelPool.shared.managerForNewSession()
        let callbackBox = LocalParakeetCallbackBox(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        await manager.setPartialCallback { partialTranscript in
            callbackBox.onTranscriptUpdate(partialTranscript)
        }
        return LocalParakeetTranscriptionSession(
            manager: manager,
            callbackBox: callbackBox
        )
    }
}

private actor LocalParakeetModelPool {
    static let shared = LocalParakeetModelPool()

    private var manager: StreamingEouAsrManager?

    func managerForNewSession() async throws -> StreamingEouAsrManager {
        if let manager {
            await manager.reset()
            return manager
        }

        let manager = StreamingEouAsrManager(
            chunkSize: .ms320,
            eouDebounceMs: 900
        )
        do {
            try await manager.loadModels()
        } catch {
            throw LocalParakeetTranscriptionError(
                message: "The local transcription model could not be prepared: \(error.localizedDescription)"
            )
        }
        self.manager = manager
        return manager
    }

    func cleanup() async {
        await manager?.cleanup()
        manager = nil
    }
}

private final class LocalParakeetCallbackBox: @unchecked Sendable {
    let onTranscriptUpdate: (String) -> Void
    let onFinalTranscriptReady: (String) -> Void
    let onError: (Error) -> Void

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }
}

private final class LocalParakeetTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 4

    private let manager: StreamingEouAsrManager
    private let callbackBox: LocalParakeetCallbackBox
    private let stateLock = NSLock()
    private var isCancelled = false
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var processingTailTask: Task<Void, Never>?

    init(
        manager: StreamingEouAsrManager,
        callbackBox: LocalParakeetCallbackBox
    ) {
        self.manager = manager
        self.callbackBox = callbackBox
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let copiedAudioBuffer = Self.copyAudioBuffer(audioBuffer), canAcceptAudio else { return }
        stateLock.lock()
        let previousTask = processingTailTask
        let nextTask = Task { [manager, callbackBox] in
            await previousTask?.value
            do {
                _ = try await manager.process(audioBuffer: copiedAudioBuffer)
            } catch {
                guard !self.isSessionCancelled else { return }
                callbackBox.onError(error)
            }
        }
        processingTailTask = nextTask
        stateLock.unlock()
    }

    func requestFinalTranscript() {
        stateLock.lock()
        guard !isCancelled, !hasRequestedFinalTranscript else {
            stateLock.unlock()
            return
        }
        hasRequestedFinalTranscript = true
        let pendingAudioProcessingTask = processingTailTask
        stateLock.unlock()

        Task {
            await pendingAudioProcessingTask?.value
            do {
                let transcript = try await manager.finish()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                deliverFinalTranscriptIfNeeded(transcript)
            } catch {
                guard !self.isSessionCancelled else { return }
                callbackBox.onError(error)
            }
        }
    }

    func cancel() {
        stateLock.lock()
        isCancelled = true
        processingTailTask?.cancel()
        processingTailTask = nil
        stateLock.unlock()
        Task { await manager.reset() }
    }

    private var canAcceptAudio: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isCancelled && !hasRequestedFinalTranscript
    }

    private var isSessionCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCancelled
    }

    private func deliverFinalTranscriptIfNeeded(_ transcript: String) {
        stateLock.lock()
        guard !isCancelled, !hasDeliveredFinalTranscript else {
            stateLock.unlock()
            return
        }
        hasDeliveredFinalTranscript = true
        stateLock.unlock()
        callbackBox.onFinalTranscriptReady(transcript)
    }

    private static func copyAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedAudioBuffer = AVAudioPCMBuffer(
            pcmFormat: audioBuffer.format,
            frameCapacity: audioBuffer.frameLength
        ) else { return nil }
        copiedAudioBuffer.frameLength = audioBuffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBuffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedAudioBuffer.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for bufferIndex in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[bufferIndex].mData,
                  let destinationData = destinationBuffers[bufferIndex].mData else { return nil }
            let byteCount = Int(sourceBuffers[bufferIndex].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[bufferIndex].mDataByteSize = sourceBuffers[bufferIndex].mDataByteSize
        }
        return copiedAudioBuffer
    }
}
