import AVFoundation
import Foundation

/// Records the microphone as 16 kHz mono samples, which is what the speech model reads.
final class Recorder {
    static let rate: Double = 16_000
    static let maxSeconds = 20 * 60

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var peak: Float = -120
    private var running = false
    var onLevel: ((Float) -> Void)?
    var onLimit: (() -> Void)?

    static func permission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "FreeFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone format is not supported."])
        }
        converter = conv
        lock.lock(); samples = []; peak = -120; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in self?.handle(buffer, outFormat) }
        engine.prepare()
        try engine.start()
        running = true
    }

    private func handle(_ buffer: AVAudioPCMBuffer, _ out: AVAudioFormat) {
        guard let conv = converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * out.sampleRate / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        conv.convert(to: converted, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.floatChannelData?[0] else { return }
        let n = Int(converted.frameLength)
        guard n > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: n))
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-7))
        lock.lock()
        samples.append(contentsOf: chunk)
        peak = max(peak, db)
        let full = samples.count >= Self.maxSeconds * Int(Self.rate)
        lock.unlock()
        onLevel?(db)
        if full { onLimit?() }
    }

    /// Stops and hands back everything heard, and how loud the loudest moment was (a very quiet take is probably silence).
    func stop() -> (samples: [Float], peakDb: Float) {
        guard running else { return ([], -120) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); defer { lock.unlock() }
        return (samples, peak)
    }
}
