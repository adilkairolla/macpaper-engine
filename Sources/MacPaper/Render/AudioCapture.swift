import Accelerate
import AVFoundation
import ScreenCaptureKit

struct AudioSpectrum: Sendable {
    var level: Float
    var bands: [Float]

    static let silent = AudioSpectrum(level: 0, bands: .init(repeating: 0, count: 16))

    var packed: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        func q(_ i: Int) -> SIMD4<Float> { SIMD4(bands[i], bands[i + 1], bands[i + 2], bands[i + 3]) }
        return (q(0), q(4), q(8), q(12))
    }
}

/// System audio through ScreenCaptureKit, reduced to 16 smoothed log-frequency bands.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = AudioCapture()

    var onSpectrum: ((AudioSpectrum) -> Void)?
    private(set) var isRunning = false
    private(set) var lastError: String?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "macpaper.audio")
    private let fftSize = 2048
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []
    private var ring: [Float] = []
    private var smooth = [Float](repeating: 0, count: 16)
    private var sampleRate: Double = 48_000
    private var lastEmit = CFAbsoluteTimeGetCurrent()

    /// Start and stop can interleave across the awaits below; `wanted` is what the app last asked for.
    private var wanted = false
    private var starting = false

    @MainActor
    func start() async {
        wanted = true
        guard stream == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            fft = vDSP.FFT(log2n: vDSP_Length(log2(Float(fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
            try await stream.startCapture()
            guard wanted else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    @MainActor
    func stop() {
        wanted = false
        guard let stream else { return }
        self.stream = nil
        isRunning = false
        Task { try? await stream.stopCapture() }
        DispatchQueue.main.async { [weak self] in self?.onSpectrum?(.silent) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.isRunning = false
            self.stream = nil
            self.lastError = message
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        if let desc = sampleBuffer.formatDescription?.audioStreamBasicDescription { sampleRate = desc.mSampleRate }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard list.count > 0, let data = list[0].mData else { return }
            let count = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            ring.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard ring.count >= fftSize, now - lastEmit >= 1.0 / 30 else { return }
        lastEmit = now
        let spectrum = analyze(Array(ring.suffix(fftSize)))
        if ring.count > fftSize * 2 { ring.removeFirst(ring.count - fftSize) }
        DispatchQueue.main.async { [weak self] in self?.onSpectrum?(spectrum) }
    }

    private func analyze(_ samples: [Float]) -> AudioSpectrum {
        guard let fft else { return .silent }
        let windowed = vDSP.multiply(samples, window)
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        let binHz = Float(sampleRate) / Float(fftSize)
        let minF: Float = 30, maxF: Float = 16_000
        var bands = [Float](repeating: 0, count: 16)
        for i in 0..<16 {
            let f0 = minF * pow(maxF / minF, Float(i) / 16)
            let f1 = minF * pow(maxF / minF, Float(i + 1) / 16)
            let b0 = max(1, Int(f0 / binHz))
            let b1 = min(half - 1, max(b0 + 1, Int(f1 / binHz)))
            var peak: Float = 0
            for b in b0..<b1 { peak = max(peak, magnitudes[b]) }
            let db = 20 * log10(max(peak / Float(fftSize) * 4, 1e-6))
            bands[i] = min(max((db + 60) / 60 * (1 + Float(i) / 16 * 0.8), 0), 1)
        }
        for i in 0..<16 {
            smooth[i] = bands[i] > smooth[i] ? bands[i] : smooth[i] * 0.82 + bands[i] * 0.18
        }
        let level = smooth.reduce(0, +) / 16
        return AudioSpectrum(level: level, bands: smooth)
    }
}
