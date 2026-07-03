import AVFoundation

/// Captures microphone audio with AVAudioEngine and accumulates it as
/// 16 kHz mono Float32 — the format Parakeet expects.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var level: Float = 0
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Smoothed input level in [0, 1] for UI metering.
    var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    static let targetSampleRate: Double = 16_000

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        // NOTE: do not enable setVoiceProcessingEnabled here — on this
        // hardware it silently zeroes the captured buffers (bars flat,
        // empty transcripts). Background-noise handling needs a different
        // approach (VAD gating or speaker enrollment).
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "LocalFlow", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input available"])
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "LocalFlow", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create target audio format"])
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns everything recorded since start().
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }

    func cancel() {
        _ = stop()
    }

    var recordedDuration: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.targetSampleRate
    }

    /// Called on the audio render thread: resample to 16 kHz mono and accumulate.
    private func append(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0,
              let channel = converted.floatChannelData?[0]
        else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        // RMS → perceptual-ish 0–1 level for the UI meter.
        var sumSquares: Float = 0
        for sample in chunk { sumSquares += sample * sample }
        let rms = (sumSquares / Float(max(chunk.count, 1))).squareRoot()
        let newLevel = min(1, pow(rms * 12, 0.7))

        lock.lock()
        samples.append(contentsOf: chunk)
        level = max(newLevel, level * 0.7)  // fast attack, slow decay
        lock.unlock()
    }
}
