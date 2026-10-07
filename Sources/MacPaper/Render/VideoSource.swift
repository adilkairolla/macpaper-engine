import AVFoundation
import CoreVideo
import Metal

struct VideoFrame {
    let luma: MTLTexture
    let chroma: MTLTexture?
    let size: CGSize
    let yuv: simd_float4x4
    let hasAlpha: Bool
    fileprivate let retain: [CVMetalTexture]
}

/// One decoder per clip, shared by every display showing it. Loops gaplessly through AVPlayerLooper, unless the
/// layer crossfades between clips: then the clip stops on its last frame and the session starts the next one.
@MainActor
final class VideoSource {
    let url: URL
    let player = AVQueuePlayer()
    /// False when the clip plays once and holds its last frame.
    let loops: Bool
    var onEnded: (() -> Void)?
    var onSettled: (() -> Void)?
    private var looper: AVPlayerLooper?
    private var item: AVPlayerItem?
    private var loopObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var introBoundary: Any?
    private var introTarget: Double?
    /// Playing the clip from the start towards `freeze`, after which it holds.
    private(set) var inIntro: Bool
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private var outputSettings: [String: Any]?
    private(set) var latest: VideoFrame?
    /// Bumped whenever `latest` changes.
    private(set) var serial = 0
    private var recent: [VideoFrame] = []
    private(set) var naturalSize = CGSize(width: 16, height: 9)
    private(set) var duration: Double = 0
    private(set) var failed: String?
    private var spec: VideoSpec
    private var speed = 1.0
    private var playing = false
    private var freezeSeeked: Double?
    private var loadTask: Task<Void, Never>?
    /// Muted clips decode no audio at all: a merely muted player still runs Core Audio and clocks every frame off it.
    private var audioEnabled = true
    private var trackObservations: [NSKeyValueObservation] = []

    init(url: URL, spec: VideoSpec, intro: Bool = false) {
        self.url = url
        self.spec = spec
        loops = spec.crossfade <= 0
        inIntro = intro && spec.freeze != nil
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        let asset = AVURLAsset(url: url)
        loadTask = Task { [weak self] in
            await self?.prepare(asset)
        }
    }

    private func prepare(_ asset: AVURLAsset) async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                failed = "no video track"
                return
            }
            let (size, transform, descs) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            naturalSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            duration = try await asset.load(.duration).seconds
            let alpha = descs.contains { desc in
                (CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool) == true
            }
            let format = alpha ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            outputSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            guard try await asset.load(.isPlayable) else {
                failed = "this video can't be decoded on macOS (use HEVC or H.264)"
                return
            }
        } catch {
            failed = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        let template = AVPlayerItem(asset: asset)
        if loops {
            let looper = AVPlayerLooper(player: player, templateItem: template)
            self.looper = looper
            for item in looper.loopingPlayerItems {
                attachOutput(item)
                observeTracks(item)
            }
            loopObservation = looper.observe(\.loopCount, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEnded?() } }
            }
        } else {
            item = template
            attachOutput(template)
            observeTracks(template)
            player.actionAtItemEnd = .pause
            player.insert(template, after: nil)
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: template, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.reachedEnd() } }
            }
        }
        applySpec()
        // A paused player decodes nothing until it seeks, and a seek issued before the item is ready is dropped.
        var waited = 0
        while player.currentItem?.status != .readyToPlay, waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { return }
            waited += 1
        }
        if !playing, spec.freeze == nil || inIntro {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        } else {
            freezeSeeked = nil
            applySpec()
        }
    }

    func seek(to seconds: Double) {
        guard duration > 0, spec.freeze == nil, loops || seconds < duration else { return }
        let t = seconds.truncatingRemainder(dividingBy: duration)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func attachOutput(_ item: AVPlayerItem) {
        guard let outputSettings, outputs[ObjectIdentifier(item)] == nil else { return }
        let out = AVPlayerItemVideoOutput(outputSettings: outputSettings)
        out.suppressesPlayerRendering = false
        item.add(out)
        outputs[ObjectIdentifier(item)] = out
    }

    var isReady: Bool { latest != nil || failed != nil }

    /// The picture is changing on its own: playing, or playing its intro towards the hold point.
    var isMoving: Bool { playing && inIntro }

    var hasLoaded: Bool { looper != nil || item != nil }

    func update(spec: VideoSpec) {
        let freezeChanged = spec.freeze != self.spec.freeze
        self.spec = spec
        if freezeChanged { freezeSeeked = nil }
        if spec.freeze == nil { inIntro = false }
        applySpec()
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        applySpec()
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        applySpec()
    }

    func setAudio(volume: Double, muted: Bool) {
        let silent = muted || volume <= 0 || spec.volume <= 0
        player.volume = Float(volume * spec.volume)
        player.isMuted = silent
        guard audioEnabled == silent else { return }
        audioEnabled = !silent
        applyAudioTracks()
    }

    private var playerItems: [AVPlayerItem] {
        looper?.loopingPlayerItems ?? item.map { [$0] } ?? []
    }

    private func observeTracks(_ item: AVPlayerItem) {
        trackObservations.append(item.observe(\.tracks, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyAudioTracks() } }
        })
    }

    private func applyAudioTracks() {
        for item in playerItems {
            for track in item.tracks where track.assetTrack?.mediaType == .audio && track.isEnabled != audioEnabled {
                track.isEnabled = audioEnabled
            }
        }
    }

    private func applySpec() {
        guard hasLoaded else { return }
        if inIntro, let freeze = spec.freeze, duration > 0 {
            armIntro(at: min(freeze, 0.999) * duration)
            return
        }
        if let freeze = spec.freeze {
            disarmIntro()
            player.pause()
            if freezeSeeked != freeze, duration > 0 {
                freezeSeeked = freeze
                let t = CMTime(seconds: min(freeze, 0.999) * duration, preferredTimescale: 600)
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }
        disarmIntro()
        let rate = Float(max(0.05, spec.rate * speed))
        player.defaultRate = rate
        if playing {
            if player.rate != rate { player.rate = rate }
        } else {
            player.pause()
        }
    }

    private func armIntro(at seconds: Double) {
        if introTarget != seconds {
            disarmIntro()
            introTarget = seconds
            let t = CMTime(seconds: seconds, preferredTimescale: 600)
            introBoundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: t)], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.settleIntro() }
            }
        }
        let rate = Float(max(0.05, spec.rate * speed))
        player.defaultRate = rate
        if playing {
            if player.rate != rate { player.rate = rate }
        } else {
            player.pause()
        }
        if let item = player.currentItem, item.currentTime().seconds >= seconds { settleIntro() }
    }

    private func disarmIntro() {
        if let introBoundary { player.removeTimeObserver(introBoundary) }
        introBoundary = nil
        introTarget = nil
    }

    private func settleIntro() {
        guard inIntro else { return }
        inIntro = false
        freezeSeeked = nil
        applySpec()
        onSettled?()
    }

    private func reachedEnd() {
        if inIntro {
            settleIntro()
            return
        }
        guard spec.freeze == nil else { return }
        onEnded?()
    }

    /// The newest decoded frame for `hostTime`, or the last one if nothing newer is due.
    func frame(hostTime: CFTimeInterval) -> VideoFrame? {
        guard let item = player.currentItem else { return latest }
        if outputs[ObjectIdentifier(item)] == nil { attachOutput(item) }
        guard let out = outputs[ObjectIdentifier(item)] else { return latest }
        let t = out.itemTime(forHostTime: hostTime)
        guard out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else {
            return latest
        }
        if let frame = makeFrame(pb) {
            latest = frame
            serial &+= 1
            recent.append(frame)
            // Keep a few frames alive: the GPU may still be sampling the previous ones.
            if recent.count > 4 { recent.removeFirst() }
        }
        return latest
    }

    private func makeFrame(_ pb: CVPixelBuffer) -> VideoFrame? {
        let cache = GPU.shared.textureCache
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if CVPixelBufferGetPlaneCount(pb) >= 2 {
            guard let y = texture(pb, cache: cache, plane: 0, format: .r8Unorm),
                  let c = texture(pb, cache: cache, plane: 1, format: .rg8Unorm),
                  let yt = CVMetalTextureGetTexture(y), let ct = CVMetalTextureGetTexture(c) else { return nil }
            return VideoFrame(luma: yt, chroma: ct, size: CGSize(width: w, height: h), yuv: Self.matrix(for: pb), hasAlpha: false, retain: [y, c])
        }
        guard let t = texture(pb, cache: cache, plane: 0, format: .bgra8Unorm), let mt = CVMetalTextureGetTexture(t) else { return nil }
        return VideoFrame(luma: mt, chroma: nil, size: CGSize(width: w, height: h), yuv: matrix_identity_float4x4, hasAlpha: true, retain: [t])
    }

    private func texture(_ pb: CVPixelBuffer, cache: CVMetalTextureCache, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        let planar = CVPixelBufferGetPlaneCount(pb) > 0
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var out: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &out)
        return out
    }

    /// Video-range Y'CbCr to RGB for the clip's colour matrix.
    static func matrix(for pb: CVPixelBuffer) -> simd_float4x4 {
        let key = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let (kr, kb): (Float, Float)
        switch key {
        case String(kCVImageBufferYCbCrMatrix_ITU_R_601_4): (kr, kb) = (0.299, 0.114)
        case String(kCVImageBufferYCbCrMatrix_ITU_R_2020): (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.2126, 0.0722)
        }
        let kg = 1 - kr - kb
        let ys: Float = 255.0 / 219.0, cs: Float = 255.0 / 224.0
        let rv = 2 * (1 - kr) * cs
        let bu = 2 * (1 - kb) * cs
        let gu = -2 * (1 - kb) * kb / kg * cs
        let gv = -2 * (1 - kr) * kr / kg * cs
        let yo: Float = 16.0 / 255.0, co: Float = 128.0 / 255.0
        // Columns multiply (y, cb, cr, 1).
        let c0 = SIMD4<Float>(ys, ys, ys, 0)
        let c1 = SIMD4<Float>(0, gu, bu, 0)
        let c2 = SIMD4<Float>(rv, gv, 0, 0)
        let c3 = SIMD4<Float>(
            -ys * yo - rv * co,
            -ys * yo - gu * co - gv * co,
            -ys * yo - bu * co,
            1
        )
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    func tearDown() {
        loadTask?.cancel()
        onEnded = nil
        onSettled = nil
        disarmIntro()
        loopObservation = nil
        trackObservations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        item = nil
        player.removeAllItems()
        outputs.removeAll()
        latest = nil
        recent.removeAll()
    }
}
