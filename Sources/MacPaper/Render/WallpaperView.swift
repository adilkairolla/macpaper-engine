import AppKit

/// One wallpaper on one surface (a desktop window, the screen saver or a preview). Shows the pre-cropped
/// poster immediately, then the live content underneath it once that has presented a frame.
@MainActor
final class WallpaperView: NSView {
    let wallpaper: Wallpaper
    let session: SceneSession
    private(set) var settings: RenderSettings
    private var content: SceneContent?
    private var incoming: SceneContent?
    private let posterLayer = CALayer()
    private let captionLayer = CaptionLayer()
    private var shownCaption = ""
    private var paused = true
    private var requestedPause = true
    private var windowHidden = false
    private var windowObservers: [NSObjectProtocol] = []
    /// Surfaces in ordinary windows (the inspector preview) also stop while their window can't be seen.
    var pausesWithWindow = false
    private var pointer: SIMD2<Float>?
    private var live = false
    private var readyHandlers: [() -> Void] = []
    private var imageHandlers: [() -> Void] = []
    private var tornDown = false
    private var posterKey = ""
    private var clockSample: Double?
    private var playingSince = CACurrentMediaTime()

    var stats: FrameStats { content?.stats ?? FrameStats() }

    init(wallpaper: Wallpaper, session: SceneSession, settings: RenderSettings, frame: NSRect) {
        self.wallpaper = wallpaper
        self.session = session
        self.settings = settings
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.masksToBounds = true
        posterLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        posterLayer.zPosition = 10
        layer?.addSublayer(posterLayer)
        captionLayer.zPosition = 20
        layer?.addSublayer(captionLayer)
        loadPoster(synchronousIfCached: true)
        rebuildContent()
        session.observe(self) { [weak self] in self?.sessionChanged() }
        applyAudio()
        session.setSpeed(settings.speed)
        session.reactionsEnabled = settings.reactions
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var pixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let rect = contentRect
        return CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }

    /// Where the wallpaper draws: the whole view, or the canvas fitted inside it with bars around.
    private var contentRect: CGRect {
        let canvas = session.scene.canvas
        guard settings.showAll, settings.span == nil, canvas.width > 0, canvas.height > 0, bounds.width > 1, bounds.height > 1 else { return bounds }
        let s = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let w = (canvas.width * s).rounded(), h = (canvas.height * s).rounded()
        return CGRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }

    private var focus: SIMD2<Double> { settings.focus ?? wallpaper.manifest.focus }

    private func loadPoster(synchronousIfCached: Bool) {
        guard bounds.width > 1, !live else { return }
        let size = pixelSize
        let span = settings.span
        let key = "\(size)|\(focus)|\(settings.showAll)|\(span.map { "\($0.rect)" } ?? "")"
        guard key != posterKey else { return }
        posterKey = key
        if let hit = PosterCache.shared.cached(wallpaper, size: size, focus: focus, span: span) {
            posterLayer.contents = hit
            fireImageHandlers()
            return
        }
        PosterCache.shared.image(wallpaper, size: size, focus: focus, span: span) { [weak self] image in
            guard let self, !self.live, self.posterKey == key else { return }
            if let image { self.posterLayer.contents = image }
            self.fireImageHandlers()
        }
    }

    override func layout() {
        super.layout()
        let rect = contentRect
        posterLayer.frame = rect
        captionLayer.frame = rect
        for c in [content, incoming].compactMap({ $0 }) where c.view.frame != rect { c.view.frame = rect }
        loadPoster(synchronousIfCached: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        captionLayer.contentsScale = window?.backingScaleFactor ?? 2
        posterKey = ""
        loadPoster(synchronousIfCached: true)
        observeWindow()
    }

    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard pausesWithWindow, let window else { return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        for name in names {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowVisibilityChanged() }
            })
        }
        windowVisibilityChanged()
    }

    private func windowVisibilityChanged() {
        guard let window else { return }
        let hidden = !window.occlusionState.contains(.visible) || window.isMiniaturized
        guard hidden != windowHidden else { return }
        windowHidden = hidden
        applyPause()
    }

    // MARK: Content

    private var wantsVideoPath: String? {
        guard settings.allowVideoFastPath, settings.grade.isIdentity, session.scene.isPlainVideo, session.canUseDirectVideo(self) else { return nil }
        return session.scene.layers.first { $0.visible && $0.video != nil }?.id
    }

    private var contentIsVideoPath: Bool { (incoming ?? content) is VideoLayerView }

    private func sessionChanged() {
        let wantsVideo = wantsVideoPath != nil
        if wantsVideo != contentIsVideoPath { rebuildContent() }
        updateCaption()
    }

    /// Lines need room to be read; small surfaces such as the inspector preview leave them out.
    private var showsCaptions: Bool { contentRect.height >= 400 }

    /// Shows the session's current line once per surface; a surface that turns up mid-line shows what's left of it.
    private func updateCaption() {
        guard showsCaptions, let spec = session.scene.captions, !spec.isOff, !paused, let caption = session.caption else {
            captionLayer.hide()
            shownCaption = ""
            return
        }
        let text = spec.text(caption.line)
        let key = "\(caption.serial)|\(text)"
        guard key != shownCaption else { return }
        let remaining = caption.duration - (CACurrentMediaTime() - caption.shownAt)
        guard remaining > 1.5 else { return }
        shownCaption = key
        captionLayer.show(text, speaker: spec.speaker, for: remaining)
    }

    private func rebuildContent() {
        guard !tornDown else { return }
        incoming?.tearDown()
        incoming?.view.removeFromSuperview()
        incoming = nil
        let next: SceneContent
        let videoLayer = wantsVideoPath
        if let id = videoLayer {
            session.claimDirectVideo(self)
            next = VideoLayerView(session: session, layerID: id, settings: settings, frame: contentRect)
        } else {
            next = MetalSceneView(session: session, settings: settings, frame: contentRect)
        }
        if let content {
            addSubview(next.view, positioned: .below, relativeTo: content.view)
        } else {
            addSubview(next.view)
        }
        incoming = next
        next.onFirstFrame = { [weak self, weak next] in
            guard let self, let next, self.incoming === next else { return }
            self.promote(next)
        }
        next.setPointer(pointer)
        next.setPaused(paused)
        // Releasing notifies every surface, this one included, so it must come after `incoming` is current.
        if videoLayer == nil { session.releaseDirectVideo(self) }
    }

    private func promote(_ next: SceneContent) {
        let old = content
        content = next
        incoming = nil
        old?.tearDown()
        old?.view.removeFromSuperview()
        guard !live else { return }
        live = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.2
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live else { return }
                self.posterLayer.contents = nil
                self.posterKey = ""
            }
        }
        posterLayer.add(fade, forKey: "fade")
        posterLayer.opacity = 0
        CATransaction.commit()
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
        fireImageHandlers()
    }

    private func fireImageHandlers() {
        let handlers = imageHandlers
        imageHandlers.removeAll()
        handlers.forEach { $0() }
    }

    // MARK: Control

    var isLive: Bool { live }

    /// Called once live frames are on screen (immediately if they already are).
    func whenLive(_ body: @escaping () -> Void) {
        if live { body() } else { readyHandlers.append(body) }
    }

    /// Called as soon as something is on screen: the poster, a live frame, or the knowledge there is no poster.
    func whenVisible(_ body: @escaping () -> Void) {
        if live || posterLayer.contents != nil || wallpaper.effectivePosterURL == nil { body() } else { imageHandlers.append(body) }
    }

    func update(settings: RenderSettings) {
        guard settings != self.settings else { return }
        let old = self.settings
        self.settings = settings
        applyAudio()
        session.setSpeed(settings.speed)
        session.reactionsEnabled = settings.reactions
        content?.apply(settings)
        incoming?.apply(settings)
        if old.showAll != settings.showAll || old.span != settings.span { needsLayout = true }
        if old.focus != settings.focus || old.showAll != settings.showAll || old.span != settings.span { posterKey = ""; loadPoster(synchronousIfCached: true) }
        if (wantsVideoPath != nil) != contentIsVideoPath { rebuildContent() }
    }

    private func applyAudio() {
        session.setAudio(volume: settings.volume, audible: !settings.muted && !paused && !tornDown, consumer: self)
    }

    func setPaused(_ paused: Bool) {
        requestedPause = paused
        applyPause()
    }

    private func applyPause() {
        let paused = requestedPause || windowHidden
        guard paused != self.paused else { return }
        self.paused = paused
        if !paused { playingSince = CACurrentMediaTime() }
        clockSample = nil
        applyAudio()
        updateCaption()
        content?.setPaused(paused)
        incoming?.setPaused(paused)
    }

    /// Why this surface looks frozen while it should be playing. The video clock is compared with the previous
    /// call, so the result means something only when called a few seconds apart.
    func stall() -> Stall? {
        guard !paused, !tornDown else {
            clockSample = nil
            return nil
        }
        guard live, let content else {
            return CACurrentMediaTime() - playingSince > 15 ? .frames : nil
        }
        if session.expectsVideoMotion {
            let clock = session.videoClock
            defer { clockSample = clock }
            if clockSample == clock { return .clock }
        } else {
            clockSample = nil
        }
        return content.stall
    }

    /// Pointer position in the view, normalized with a top-left origin; nil when it left.
    func setPointer(_ point: SIMD2<Float>?) {
        pointer = point
        content?.setPointer(point)
        incoming?.setPointer(point)
    }

    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        applyAudio()
        session.unobserve(self)
        session.releaseDirectVideo(self)
        for c in [content, incoming].compactMap({ $0 }) {
            c.tearDown()
            c.view.removeFromSuperview()
        }
        content = nil
        incoming = nil
        SessionStore.shared.release(session)
    }
}
