import AppKit
import Metal
import QuartzCore
import simd

/// Why a surface that should be moving isn't.
enum Stall: String {
    case clock = "the video clock stopped"
    case frames = "no new frames were drawn"
    case layer = "the video layer never showed a frame"
    case sharedPlayer = "two video layers shared one player"
}

@MainActor
protocol SceneContent: AnyObject {
    var view: NSView { get }
    var onFirstFrame: (() -> Void)? { get set }
    var stats: FrameStats { get }
    /// Checked every few seconds by the desktop's freeze guard.
    var stall: Stall? { get }
    func setPaused(_ paused: Bool)
    func setPointer(_ point: SIMD2<Float>?)
    func apply(_ settings: RenderSettings)
    func tearDown()
}

/// Draws a scene with Metal into a CAMetalLayer, paced by the display's own refresh.
@MainActor
final class MetalSceneView: NSView, SceneContent {
    let session: SceneSession
    var onFirstFrame: (() -> Void)?
    private(set) var stats = FrameStats(path: "Metal")
    var view: NSView { self }

    private let metalLayer = CAMetalLayer()
    private let encoder: SceneEncoder
    private var settings: RenderSettings
    private var link: CADisplayLink?
    private var paused = true
    private var needsRender = true
    private var burstUntil: CFTimeInterval = 0
    private var lastTick: CFTimeInterval?
    private var createdAt = CACurrentMediaTime()
    private var firstFramePresented = false
    private var inFlight = 0
    private var pointer: SIMD2<Float>?
    private var lastVideoToken = Int.min
    private var parallax = SIMD2<Float>.zero
    private var ambientCheckedAt: CFTimeInterval = 0
    private var daylight = Ambient.daylight()
    private var dark: Float = Ambient.isDark ? 1 : 0
    private var frameTimes: [CFTimeInterval] = []
    private var tornDown = false
    private var lastPresentAt = CACurrentMediaTime()

    /// A window macOS reports as hidden gets no display-link ticks, so only a visible one can be judged.
    var stall: Stall? {
        guard !paused, !tornDown, firstFramePresented, session.isRunning, session.scene.isAnimated,
              window?.occlusionState.contains(.visible) == true else { return nil }
        return CACurrentMediaTime() - lastPresentAt > 5 ? .frames : nil
    }

    init(session: SceneSession, settings: RenderSettings, frame: NSRect) {
        self.session = session
        self.settings = settings
        encoder = SceneEncoder(session: session)
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = GPU.shared.device
        metalLayer.pixelFormat = GPU.shared.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.backgroundColor = NSColor.black.cgColor
        session.observe(self) { [weak self] in self?.invalidate(burst: 1.0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil, !tornDown else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        applyFrameRate()
        updateDrawableSize()
        link.isPaused = paused
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        guard metalLayer.drawableSize != size else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        invalidate()
    }

    private var targetFPS: Int {
        let own = session.scene.fps
        let cap = settings.fpsCap > 0 ? settings.fpsCap : own
        return max(1, min(own, cap, settings.maxFPS))
    }

    private func applyFrameRate() {
        let fps = Float(targetFPS)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 24), maximum: fps, preferred: fps)
    }

    func apply(_ settings: RenderSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        applyFrameRate()
        invalidate(burst: 1.5)
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused || lastTick == nil else { return }
        self.paused = paused
        session.setPlaying(!paused, consumer: self)
        lastTick = nil
        if paused {
            link?.isPaused = true
        } else {
            invalidate()
        }
    }

    func setPointer(_ point: SIMD2<Float>?) {
        guard point != pointer else { return }
        pointer = point
        if settings.pointerParallax, session.scene.usesParallax || hasPointerParticles {
            invalidate(burst: 2)
        }
    }

    private var hasPointerParticles: Bool {
        session.scene.hasPointerParticles
    }

    private func invalidate(burst: Double = 0) {
        needsRender = true
        if burst > 0 { burstUntil = max(burstUntil, CACurrentMediaTime() + burst) }
        if !paused { link?.isPaused = false }
    }

    private var parallaxTarget: SIMD2<Float> {
        let scene = session.scene
        var t = SIMD2<Float>.zero
        if settings.pointerParallax, let p = pointer {
            t = (p - 0.5) * 2
        }
        if scene.drift > 0 {
            let time = Float(session.time(at: CACurrentMediaTime()))
            let d = Float(scene.drift)
            t += SIMD2(sin(time * 0.21) * 0.7 + sin(time * 0.13 + 1.3) * 0.3, cos(time * 0.17) * 0.6 + sin(time * 0.09 + 0.4) * 0.4) * d
        }
        return simd_clamp(t, SIMD2(repeating: -1), SIMD2(repeating: 1))
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !paused, !tornDown else { link.isPaused = true; return }
        let now = CACurrentMediaTime()
        let dt = min(lastTick.map { now - $0 } ?? (1.0 / Double(targetFPS)), 0.25)
        lastTick = now

        if now - ambientCheckedAt > 5 {
            ambientCheckedAt = now
            let d = Ambient.daylight(), k: Float = Ambient.isDark ? 1 : 0
            if d != daylight || k != dark {
                daylight = d
                dark = k
                needsRender = true
            }
        }

        let scene = session.scene
        let target = scene.usesParallax || scene.layers.contains(where: { if case .shader = $0.content { true } else { false } }) ? parallaxTarget : .zero
        let ease = Float(1 - exp(-dt * 3))
        let moving = simd_length(target - parallax) > 0.0005
        parallax += (target - parallax) * ease

        let continuous = (session.isRunning && (scene.isAnimated || session.hasTransientMotion)) || (scene.usesParallax && (moving || (session.isRunning && scene.drift > 0)))
        if !continuous && !needsRender && now > burstUntil {
            link.isPaused = true
            return
        }
        guard firstFramePresented || session.isReady || now - createdAt > 4 else { return }
        guard inFlight < 2 else { return }
        let otherMotion = needsRender || now <= burstUntil || !firstFramePresented || session.isCrossfading
            || (scene.usesParallax && (moving || (session.isRunning && scene.drift > 0)))
        if scene.animatedOnlyByVideo, !otherMotion {
            let token = session.videoFrameToken(hostTime: link.targetTimestamp)
            guard token != lastVideoToken else { return }
            lastVideoToken = token
        }
        render(hostTime: link.targetTimestamp, dt: dt)
        needsRender = false
    }

    private func render(hostTime: CFTimeInterval, dt: Double) {
        guard metalLayer.drawableSize.width > 1, let drawable = metalLayer.nextDrawable(),
              let cb = GPU.shared.queue.makeCommandBuffer() else { return }
        cb.label = "MacPaper frame"
        let cpuStart = CACurrentMediaTime()
        var grade = settings.grade
        if grade.isIdentity { grade = GradeUniforms() }
        let input = FrameInput(
            hostTime: hostTime,
            dt: dt,
            outputSize: metalLayer.drawableSize,
            renderScale: settings.renderScale,
            focus: settings.focus ?? session.wallpaper.manifest.focus,
            parallax: parallax,
            parallaxStrength: settings.parallaxStrength,
            pointer: pointer,
            grade: grade,
            daylight: daylight,
            dark: dark,
            span: settings.span
        )
        encoder.encode(cb, output: drawable.texture, input: input)
        if !firstFramePresented {
            drawable.addPresentedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.firstPresented() }
                }
            }
        }
        cb.present(drawable)
        lastPresentAt = CACurrentMediaTime()
        let cpu = (CACurrentMediaTime() - cpuStart) * 1000
        inFlight += 1
        let session = self.session
        cb.addCompletedHandler { [weak self] cb in
            let gpu = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            let code = (cb.error as NSError?).flatMap { MTLCommandBufferError.Code(rawValue: UInt($0.code)) }
            let failed = cb.status == .error && [.pageFault, .timeout, .stackOverflow].contains(code)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if failed { session.reportGPUFault() }
                    guard let self else { return }
                    self.inFlight -= 1
                    self.record(cpu: cpu, gpu: gpu)
                }
            }
        }
        cb.commit()
    }

    private func firstPresented() {
        guard !firstFramePresented else { return }
        firstFramePresented = true
        onFirstFrame?()
    }

    private func record(cpu: Double, gpu: Double) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        stats.fps = Double(frameTimes.count)
        stats.cpuMs = stats.cpuMs * 0.9 + cpu * 0.1
        stats.gpuMs = stats.gpuMs * 0.9 + gpu * 0.1
    }

    func tearDown() {
        tornDown = true
        link?.invalidate()
        link = nil
        session.unobserve(self)
    }
}
