import AppKit
import ScreenSaver

/// The same renderer as the desktop, inside legacyScreenSaver. Metal draws in-process here, which the
/// lock screen presents — unlike WebKit's out-of-process content.
@objc(MacPaperSaverView)
final class MacPaperSaverView: ScreenSaverView {
    private var prefs = SaverPreferences()
    private var state = AppState()
    private var library: [Wallpaper] = []
    private var current: WallpaperView?
    private var outgoing: WallpaperView?
    private var rotateTimer: Timer?
    private var cycleTimers: [Timer] = []
    private var clipObserver: NSObjectProtocol?
    /// The shown wallpaper's control values as the saver's own cycling moves them; never written back.
    private var values: [String: JSONValue] = [:]
    private var stopObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    private var paused = true

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func startAnimation() {
        super.startAnimation()
        prefs = SaverPreferences.load()
        state = AppState.load()
        library = LibraryStore.read(linked: state.linked.map { URL(fileURLWithPath: $0, isDirectory: true) }).0
        // Occlusion reads hidden for the whole run on macOS 26, so start/stop and display sleep decide playback.
        paused = false
        show(pick())
        if !isPreview { scheduleRotation() }
        if sleepObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            sleepObservers = [
                center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setPaused(true) }
                },
                center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setPaused(false) }
                },
            ]
        }
        clipObserver = clipObserver ?? NotificationCenter.default.addObserver(forName: SceneSession.clipEnded, object: nil, queue: nil) { [weak self] n in
            let session = n.object as? SceneSession
            MainActor.assumeIsolated { self?.clipEnded(session) }
        }
        // legacyScreenSaver often skips stopAnimation and keeps old views alive after the saver ends.
        stopObserver = stopObserver ?? DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screensaver.willstop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        stop()
    }

    private func setPaused(_ value: Bool) {
        guard current != nil, value != paused else { return }
        paused = value
        current?.setPaused(paused)
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    private var screenKey: String { (window?.screen ?? NSScreen.main)?.stableKey ?? AppState.allDisplaysKey }

    private func pick() -> Wallpaper? {
        func wallpaper(_ id: String?) -> Wallpaper? { id.flatMap { id in library.first { $0.id == id } } }
        let desktop = wallpaper(state.wallpaperID(forDisplay: screenKey, perDisplay: prefs.perDisplay)) ?? state.recents.lazy.compactMap(wallpaper).first
        switch prefs.source {
        case .desktop:
            return desktop ?? library.first
        case .wallpaper:
            return wallpaper(prefs.wallpaperID) ?? desktop ?? library.first
        case .favorites, .library:
            let favorites = library.filter { state.favorites.contains($0.id) }
            let pool = prefs.source == .favorites && !favorites.isEmpty ? favorites : library
            return pool.filter { $0.id != current?.wallpaper.id }.randomElement() ?? pool.first ?? desktop
        }
    }

    private func settings(for wp: Wallpaper) -> RenderSettings {
        let s = state.settings(wp.id)
        var r = RenderSettings()
        r.focus = s.focus(for: screenKey)
        r.showAll = s.showAll
        r.speed = s.speed
        r.fpsCap = isPreview ? 15 : (s.fpsCap > 0 ? s.fpsCap : prefs.frameRateCap)
        r.grade = s.grade
        r.parallaxStrength = s.parallax
        r.pointerParallax = false
        r.renderScale = isPreview ? 0.5 : prefs.quality.renderScale
        r.volume = s.volume
        r.muted = isPreview || !prefs.sound
        r.maxFPS = (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        return r
    }

    private func show(_ wp: Wallpaper?) {
        guard let wp, wp != current?.wallpaper else { return }
        values = state.settings(wp.id).values
        let session = SessionStore.shared.acquire(wp, values: values)
        let view = WallpaperView(wallpaper: wp, session: session, settings: settings(for: wp), frame: bounds)
        view.autoresizingMask = [.width, .height]
        if let old = outgoing {
            old.tearDown()
            old.removeFromSuperview()
        }
        outgoing = current
        if outgoing != nil { view.alphaValue = 0 }
        addSubview(view)
        current = view
        view.setPaused(paused)
        scheduleCycles(for: wp)
        view.whenVisible { [weak self, weak view] in
            guard let self, let view, self.current === view, let old = self.outgoing else { return }
            self.outgoing = nil
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 1.2
                view.animator().alphaValue = 1
            } completionHandler: {
                MainActor.assumeIsolated {
                    old.tearDown()
                    old.removeFromSuperview()
                }
            }
        }
    }

    private func scheduleRotation() {
        rotateTimer?.invalidate()
        guard prefs.source == .favorites || prefs.source == .library, prefs.rotateMinutes > 0 else { return }
        rotateTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(prefs.rotateMinutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.show(self.pick())
            }
        }
    }

    private func scheduleCycles(for wp: Wallpaper) {
        cycleTimers.forEach { $0.invalidate() }
        cycleTimers.removeAll()
        guard !isPreview else { return }
        for (controlID, cycle) in state.settings(wp.id).cycles(for: wp.manifest) where cycle.minutes > 0 && !cycle.afterClip {
            cycleTimers.append(Timer.scheduledTimer(withTimeInterval: TimeInterval(cycle.minutes * 60), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance(controlID, cycle: cycle) }
            })
        }
    }

    private func clipEnded(_ session: SceneSession?) {
        guard !isPreview, let current, current.session === session else { return }
        for (controlID, cycle) in state.settings(current.wallpaper.id).cycles(for: current.wallpaper.manifest) where cycle.afterClip {
            advance(controlID, cycle: cycle)
        }
    }

    private func advance(_ controlID: String, cycle: CycleSetting) {
        guard !paused, let wp = current?.wallpaper,
              let control = wp.manifest.allControls.first(where: { $0.id == controlID }),
              let next = cycle.next(after: SceneResolver.effectiveValues(wp.manifest, stored: values)[controlID], in: control)
        else { return }
        values[controlID] = next
        SessionStore.shared.update(wallpaperID: wp.id, values: values)
    }

    private func stop() {
        rotateTimer?.invalidate()
        rotateTimer = nil
        cycleTimers.forEach { $0.invalidate() }
        cycleTimers.removeAll()
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
        stopObserver = nil
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObservers.removeAll()
        for v in [outgoing, current].compactMap({ $0 }) {
            v.tearDown()
            v.removeFromSuperview()
        }
        outgoing = nil
        current = nil
        paused = true
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? { ConfigureSheet() }
}

final class ConfigureSheet: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        let title = NSTextField(labelWithString: "MacPaper Screen Saver")
        title.font = .boldSystemFont(ofSize: 14)
        let body = NSTextField(wrappingLabelWithString: "Choose what plays, how often it changes and whether it makes sound in MacPaper, under Screen Saver.")
        body.textColor = .secondaryLabelColor
        let open = NSButton(title: "Open MacPaper", target: self, action: #selector(openApp))
        open.keyEquivalent = "\r"
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        done.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [done, open])
        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
    }

    @objc private func openApp() {
        NSWorkspace.shared.open(URL(string: "macpaper://screensaver")!)
        dismiss()
    }

    @objc private func dismiss() {
        if let parent = sheetParent { parent.endSheet(self) } else { orderOut(nil) }
    }
}
