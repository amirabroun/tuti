import AVFoundation

/// Microphone → float32 mono chunks at the hardware rate (~85 ms each at 48 kHz).
/// The server resamples, so the only conversion here is downmixing to mono.
final class MicStreamer {
    var onChunk: ((Data) -> Void)?  // audio thread
    var onLevel: ((Float) -> Void)?  // peak dBFS of each chunk, audio thread
    private(set) var sampleRate: Double = 48000

    private let engine = AVAudioEngine()
    private var running = false

    func start() throws {
        guard !running else { return }  // a second tap on the same bus crashes AVAudioEngine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw NSError(domain: "Tuti", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
        }
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<count {
            for i in 0..<n { mono[i] += channels[c][i] }
        }
        if count > 1 {
            for i in 0..<n { mono[i] /= Float(count) }
        }
        let peak = mono.reduce(0) { max($0, abs($1)) }
        onLevel?(20 * log10(max(peak, 1e-6)))
        onChunk?(mono.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
