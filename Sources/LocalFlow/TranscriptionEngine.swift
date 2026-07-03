import Foundation
import FluidAudio

/// On-device speech-to-text: Parakeet-TDT-0.6B-v3 as CoreML on the Apple
/// Neural Engine, via FluidAudio. Models are fetched from HuggingFace once
/// (~600 MB into ~/Library/Application Support/FluidAudio/Models) and every
/// transcription after that runs entirely offline.
actor TranscriptionEngine {
    enum State: Equatable {
        case idle
        case downloading(percent: Int)
        case loading
        case ready
        case failed(String)
    }

    private var manager: AsrManager?
    private(set) var state: State = .idle
    private let onStateChange: @Sendable (State) -> Void

    init(onStateChange: @escaping @Sendable (State) -> Void) {
        self.onStateChange = onStateChange
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange(newState)
    }

    func load() async {
        guard manager == nil else { return }
        setState(.downloading(percent: 0))
        do {
            let models = try await AsrModels.downloadAndLoad(progressHandler: { progress in
                Task { await self.reportDownload(progress) }
            })
            setState(.loading)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func reportDownload(_ progress: DownloadUtils.DownloadProgress) {
        if case .downloading = state {
            setState(.downloading(percent: Int(progress.fractionCompleted * 100)))
        }
    }

    /// Transcribe one utterance of 16 kHz mono samples. Each utterance is
    /// independent, so decoder state starts fresh every call.
    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        guard let manager else {
            throw NSError(domain: "LocalFlow", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Speech model is not loaded yet"])
        }
        var decoderState = try TdtDecoderState()
        return try await manager.transcribe(samples, decoderState: &decoderState)
    }

    /// Transcribe an audio file (any format AVFoundation can read).
    func transcribe(url: URL) async throws -> ASRResult {
        guard let manager else {
            throw NSError(domain: "LocalFlow", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Speech model is not loaded yet"])
        }
        var decoderState = try TdtDecoderState()
        return try await manager.transcribe(url, decoderState: &decoderState)
    }
}
