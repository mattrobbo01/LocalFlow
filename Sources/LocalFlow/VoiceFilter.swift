import Foundation
import FluidAudio
import os

/// Speaker verification: enroll the owner's voice once, then keep only their
/// speech segments in each dictation — TV dialogue and other voices are cut
/// before the audio ever reaches the ASR model. All on-device (pyannote
/// segmentation + WeSpeaker embeddings via FluidAudio CoreML).
actor VoiceFilter {
    private let logger = Logger(subsystem: "com.mattrobertson.localflow", category: "voice")
    private var diarizer: DiarizerManager?
    private var profile: [Float]?

    static var profileURL: URL { Settings.directory.appendingPathComponent("voice-profile.json") }

    var isEnrolled: Bool { profile != nil }

    /// Load the saved profile (if any) and warm up the diarization models.
    func loadIfEnrolled() async {
        guard let data = try? Data(contentsOf: Self.profileURL),
              let embedding = try? JSONDecoder().decode([Float].self, from: data)
        else { return }
        profile = embedding
        await ensureModels()
    }

    private func ensureModels() async {
        guard diarizer == nil else { return }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizer = manager
            logger.info("diarization models ready")
        } catch {
            logger.error("diarization models failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Build the owner's voice profile from an enrollment recording
    /// (16 kHz mono, ideally 15–30 s of natural speech).
    func enroll(samples: [Float]) async throws {
        await ensureModels()
        guard let diarizer else {
            throw NSError(domain: "LocalFlow", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Voice models unavailable"])
        }
        let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        profile = embedding
        let data = try JSONEncoder().encode(embedding)
        try FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        try data.write(to: Self.profileURL)
        logger.info("voice profile enrolled (\(embedding.count) dims)")
    }

    func removeProfile() {
        profile = nil
        try? FileManager.default.removeItem(at: Self.profileURL)
    }

    /// Keep only segments spoken by the enrolled voice. Fail-open: with no
    /// profile, no models, or a diarization error, the audio passes through
    /// untouched — a filter problem must never eat a dictation.
    func filter(_ samples: [Float], threshold: Float) async -> [Float] {
        guard let profile else { return samples }
        await ensureModels()
        guard let diarizer else { return samples }

        do {
            let result = try diarizer.performCompleteDiarization(samples)
            guard !result.segments.isEmpty else { return samples }

            let sampleRate: Float = 16_000
            var kept: [Float] = []
            var keptSegments = 0
            for segment in result.segments {
                let start = max(0, Int(segment.startTimeSeconds * sampleRate))
                let end = min(samples.count, Int(segment.endTimeSeconds * sampleRate))
                guard end > start else { continue }

                var distance = 1 - Self.cosineSimilarity(segment.embedding, profile)
                if distance >= threshold {
                    // Partial-window segments (typically the trailing chunk of a
                    // recording) come back with garbage embeddings — the window
                    // is mostly padding. Re-fingerprint from the segment's own
                    // samples, tiled to a full window, before rejecting.
                    let retried = retryDistance(
                        samples: Array(samples[start..<end]), diarizer: diarizer)
                    if let retried {
                        distance = min(distance, retried)
                    }
                }
                logger.info(
                    "segment \(String(format: "%.1f–%.1fs", segment.startTimeSeconds, segment.endTimeSeconds), privacy: .public) distance \(String(format: "%.2f", distance), privacy: .public)")
                guard distance < threshold else { continue }
                kept.append(contentsOf: samples[start..<end])
                keptSegments += 1
            }
            logger.info("voice filter kept \(keptSegments)/\(result.segments.count) segments")
            return kept
        } catch {
            logger.error("diarization failed, passing audio through: \(error.localizedDescription, privacy: .public)")
            return samples
        }
    }

    /// Second-opinion match: tile the segment's samples to a full 10 s
    /// analysis window (repeating the same voice instead of zero-padding)
    /// and extract a clean embedding. Returns nil if the segment is too
    /// short to judge or extraction fails.
    private func retryDistance(samples: [Float], diarizer: DiarizerManager) -> Float? {
        guard let profile else { return nil }
        let minSamples = 8_000  // 0.5 s of real speech minimum
        guard samples.count >= minSamples else { return nil }

        let windowSamples = 160_000  // 10 s @ 16 kHz
        var tiled = samples
        tiled.reserveCapacity(windowSamples)
        while tiled.count < windowSamples {
            tiled.append(contentsOf: samples.prefix(windowSamples - tiled.count))
        }

        guard let embedding = try? diarizer.extractSpeakerEmbedding(from: tiled) else { return nil }
        return 1 - Self.cosineSimilarity(embedding, profile)
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = (normA.squareRoot() * normB.squareRoot())
        return denominator > 0 ? dot / denominator : 0
    }
}
