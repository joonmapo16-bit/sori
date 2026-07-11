import FluidAudio
import Foundation
import os

/// Keeps a loaded `StreamingNemotronMultilingualAsrManager` alive across sessions
/// so `connect()` doesn't pay the ~22s CoreML load on every recording. A fresh
/// provider is created per recording, so the cache must be process-wide.
private actor NemotronManagerCache {
    static let shared = NemotronManagerCache()

    private var managers: [String: StreamingNemotronMultilingualAsrManager] = [:]

    /// Checks out a warm manager (removed from the cache while in use).
    func take(for key: String) -> StreamingNemotronMultilingualAsrManager? {
        managers.removeValue(forKey: key)
    }

    /// Returns a still-loaded manager to the cache for reuse.
    func put(_ manager: StreamingNemotronMultilingualAsrManager, for key: String) {
        managers[key] = manager
    }

    /// Whether a warm manager is already cached (and not currently checked out).
    func contains(_ key: String) -> Bool {
        managers[key] != nil
    }
}

/// True streaming provider backed by FluidAudio's Nemotron multilingual manager.
final class FluidAudioNemotronStreamingProvider: StreamingTranscriptionProvider {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioNemotronStreaming")
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var cacheKey: String?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init() {
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation?.finish()
    }

    /// Preloads the Nemotron model into the warm cache so the first real
    /// `connect()` after model selection / launch is instant instead of paying
    /// the one-time ~22s CoreML load during the user's first dictation.
    /// No-op if already warm. Safe to call repeatedly.
    static func warmUp(model: any TranscriptionModel) {
        // Capture only Sendable values (URL/String); never the non-Sendable model.
        let cacheDirectory = FluidAudioModelManager.nemotronCacheDirectory(for: model.name)
        let key = cacheDirectory.path
        let displayName = model.displayName
        Task.detached(priority: .utility) {
            let logger = Logger(
                subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioNemotronStreaming")
            if await NemotronManagerCache.shared.contains(key) { return }
            do {
                let manager = StreamingNemotronMultilingualAsrManager()
                try await manager.loadModels(from: cacheDirectory)
                await NemotronManagerCache.shared.put(manager, for: key)
                logger.notice("Nemotron streaming warmed up for \(displayName, privacy: .public)")
            } catch {
                logger.error("Nemotron warmup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let cacheDirectory = FluidAudioModelManager.nemotronCacheDirectory(for: model.name)
        let key = cacheDirectory.path
        self.cacheKey = key
        let continuation = eventsContinuation

        let manager: StreamingNemotronMultilingualAsrManager
        if let warm = await NemotronManagerCache.shared.take(for: key) {
            // Reuse an already-loaded manager: reset streaming state only, keep models resident.
            manager = warm
            await manager.reset()
            logger.notice("Nemotron streaming reused warm model for \(model.displayName, privacy: .public)")
        } else {
            // Cold start: pay the one-time CoreML load. Subsequent sessions reuse this manager.
            manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: cacheDirectory)
        }

        await manager.setPartialCallback { partial in
            continuation?.yield(.partial(text: partial))
        }
        let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
            language,
            for: model
        )
        let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
        await manager.setLanguage(languageHint)

        self.manager = manager
        eventsContinuation?.yield(.sessionStarted)
        logger.notice("Nemotron streaming started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        let samples = PCMAudioConverter.float32Samples(fromPCM16Data: data)
        guard !samples.isEmpty else { return }

        _ = try await manager.process(samples: samples)
    }

    func commit() async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        let finalText = try await manager.finish()
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TextNormalizer.shared.normalizeSentence(text)
        eventsContinuation?.yield(.committed(text: normalized))
    }

    func disconnect() async {
        // Keep the loaded models resident: reset streaming state and return the
        // manager to the warm cache instead of tearing it down with cleanup().
        if let manager, let cacheKey {
            await manager.reset()
            await NemotronManagerCache.shared.put(manager, for: cacheKey)
        } else {
            await manager?.cleanup()
        }
        manager = nil
        eventsContinuation?.finish()
        logger.notice("Nemotron streaming disconnected")
    }
}
