import AppKit
import Observation

struct DisplayInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let size: CGSize
    let pixelSize: CGSize
    var wallpaperID: String?
    var paused: Bool
    var recoveries = 0
    var lastRecovery: String?
}

/// One borderless window per screen at desktop level, each hosting a WallpaperView.
@MainActor
@Observable
final class DesktopManager {
    @MainActor
    private final class Slot {
        let key: String
        var screen: NSScreen
        let window: DesktopWindow
        let stage = NSView()
        var view: WallpaperView?
        var outgoing: WallpaperView?
        var wallpaperID: String?
        var occluded = false
        var paused = false
        var observer: NSObjectProtocol?
        var strikes = 0
        var recoveries: [Date] = []
        var totalRecoveries = 0
        var lastRecovery: String?
        var gaveUp = false

        init(screen: NSScreen) {
            key = screen.stableKey
            self.screen = screen
            window = DesktopWindow(screen: screen)
            stage.wantsLayer = true
            stage.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = stage
        }
    }

    private(set) var displays: [DisplayInfo] = []
    var userPaused = false { didSet { evaluatePolicy() } }

    @ObservationIgnored private var slots: [Slot] = []
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let monitor: SystemMonitor
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var lastMouse = CFAbsoluteTimeGetCurrent()
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var coverageTimer: Timer?
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var peakIdle: Double = 0
    @ObservationIgnored var assignment: ((String) -> Wallpaper?)?
    @ObservationIgnored var values: ((Wallpaper) -> [String: JSONValue])?
    @ObservationIgnored var settings: ((Wallpaper, String) -> RenderSettings)?

    init(prefs: Preferences, monitor: SystemMonitor) {
        self.prefs = prefs
        self.monitor = monitor
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreens() }
        }
        AudioCapture.shared.onSpectrum = { spectrum in
            MainActor.assumeIsolated {
                SessionStore.shared.all.forEach { $0.spectrum = spectrum }
            }
        }
        monitor.onReactionEvent = { [weak self] trigger in
            // Unlocking and waking resume playback a moment later; a paused wallpaper doesn't react.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { self?.react(trigger) }
            }
        }
        trackPolicyInputs()
    }

    // MARK: Screens

    /// NSScreen compares equal by display, so a slot could keep an object from before the reconfiguration
    /// and place its window at the old frame, off its screen. Slots are rebound to the current objects.
    func rebuildScreens() {
        let screens = NSScreen.screens
        let current = Dictionary(screens.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
        for slot in slots where current[slot.key] == nil {
            teardown(slot)
        }
        slots.removeAll { current[$0.key] == nil }
        for screen in screens {
            if let slot = slots.first(where: { $0.key == screen.stableKey }) {
                slot.screen = screen
                continue
            }
            let slot = Slot(screen: screen)
            slot.observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: slot.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCoverage() }
            }
            slots.append(slot)
        }
        for slot in slots {
            slot.window.setFrame(slot.screen.frame, display: true)
        }
        reloadAssignments()
    }

    /// Re-reads which wallpaper belongs on each screen and swaps where it changed.
    func reloadAssignments() {
        for slot in slots {
            let wp = assignment?(slot.key)
            let stale = wp.map { w in slot.view.map { $0.wallpaper.stamp != w.stamp || $0.wallpaper.url != w.url } ?? true } ?? false
            if wp?.id != slot.wallpaperID || stale {
                show(wp, in: slot)
            }
        }
        // Spanning depends on what every other display shows, so the unchanged ones re-read their settings too.
        refreshSettings()
    }

    func reload(wallpaperID: String) {
        for slot in slots where slot.wallpaperID == wallpaperID {
            show(assignment?(slot.key), in: slot)
        }
        publish()
    }

    private func show(_ wallpaper: Wallpaper?, in slot: Slot) {
        if let outgoing = slot.outgoing {
            discard(outgoing)
            slot.outgoing = nil
        }
        slot.outgoing = slot.view
        slot.view = nil
        slot.wallpaperID = wallpaper?.id
        guard let wallpaper, let values = values?(wallpaper), let settings = settings?(wallpaper, slot.key) else {
            if let o = slot.outgoing { discard(o) }
            slot.outgoing = nil
            slot.window.orderOut(nil)
            return
        }
        let session = SessionStore.shared.acquire(wallpaper, values: values)
        let view = WallpaperView(wallpaper: wallpaper, session: session, settings: settings, frame: slot.stage.bounds)
        view.autoresizingMask = [.width, .height]
        let fade = prefs.transitionSeconds
        if slot.outgoing != nil, fade > 0 { view.alphaValue = 0 }
        slot.stage.addSubview(view)
        slot.view = view
        slot.window.orderFrontRegardless()
        evaluatePolicy()
        view.whenVisible { [weak self, weak slot, weak view] in
            guard let self, let slot, let view, slot.view === view, let outgoing = slot.outgoing else { return }
            slot.outgoing = nil
            guard fade > 0 else {
                self.discard(outgoing)
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.discard(outgoing) }
            }
        }
    }

    private func discard(_ view: WallpaperView) {
        view.tearDown()
        view.removeFromSuperview()
    }

    private func teardown(_ slot: Slot) {
        if let o = slot.outgoing { discard(o) }
        if let v = slot.view { discard(v) }
        slot.outgoing = nil
        slot.view = nil
        slot.window.orderOut(nil)
        if let o = slot.observer { NotificationCenter.default.removeObserver(o) }
    }

    func tearDownAll() {
        slots.forEach(teardown)
        slots.removeAll()
        AudioCapture.shared.stop()
    }

    // MARK: Live updates

    func refreshSettings(wallpaperID: String? = nil) {
        for slot in slots {
            guard let view = slot.view, wallpaperID == nil || view.wallpaper.id == wallpaperID,
                  let s = settings?(view.wallpaper, slot.key) else { continue }
            view.update(settings: s)
        }
        evaluatePolicy()
    }

    func stats(for displayKey: String) -> FrameStats? {
        slots.first { $0.key == displayKey }?.view?.stats
    }

    func screen(for displayKey: String) -> NSScreen? {
        slots.first { $0.key == displayKey }?.screen
    }

    // MARK: Policy

    private func trackPolicyInputs() {
        withObservationTracking {
            _ = prefs.pauseWhenCovered
            _ = prefs.pauseOnBattery
            _ = prefs.pauseInLowPowerMode
            _ = prefs.pauseWithReduceMotion
            _ = prefs.focusBehavior
            _ = prefs.globalMute
            _ = prefs.masterVolume
            _ = prefs.audioReactive
            _ = prefs.frameRateCap
            _ = prefs.quality
            _ = prefs.batteryQuality
            _ = prefs.pointerParallax
            _ = monitor.onBattery
            _ = monitor.lowPowerMode
            _ = monitor.reduceMotion
            _ = monitor.screensAsleep
            _ = monitor.screenLocked
            _ = monitor.screenSaverRunning
            _ = monitor.frontmostIsOther
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshSettings()
                    self.updateAudioCapture()
                    self.trackPolicyInputs()
                }
            }
        }
    }

    var pauseReason: String? {
        if userPaused { return "Paused" }
        if monitor.screensAsleep { return "Display asleep" }
        if monitor.screenLocked { return "Screen locked" }
        if monitor.screenSaverRunning { return "Screen saver running" }
        if prefs.pauseOnBattery && monitor.onBattery { return "On battery" }
        if prefs.pauseInLowPowerMode && monitor.lowPowerMode { return "Low Power Mode" }
        if prefs.pauseWithReduceMotion && monitor.reduceMotion { return "Reduce Motion is on" }
        if prefs.focusBehavior == .pause && monitor.frontmostIsOther { return "Another app is focused" }
        return nil
    }

    var focusMuted: Bool { prefs.focusBehavior == .mute && monitor.frontmostIsOther }

    func evaluatePolicy() {
        let globalPause = pauseReason != nil
        for slot in slots {
            let paused = globalPause || (prefs.pauseWhenCovered && slot.occluded)
            slot.paused = paused
            slot.view?.setPaused(paused)
            slot.outgoing?.setPaused(paused)
        }
        publish()
        updateAudioCapture()
        updateCoverageTimer(globalPause: globalPause)
        updatePointerTracking()
        updateHealthTimer()
        updateReactionInputs()
    }

    /// Coverage only matters while something could play, so the window-list poll stops otherwise.
    private func updateCoverageTimer(globalPause: Bool) {
        let wanted = prefs.pauseWhenCovered && !globalPause && slots.contains { $0.view != nil }
        if wanted, coverageTimer == nil {
            coverageTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCoverage() }
            }
            coverageTimer?.tolerance = 0.5
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.updateCoverage() } }
        } else if !wanted, let timer = coverageTimer {
            timer.invalidate()
            coverageTimer = nil
            if slots.contains(where: \.occluded) {
                slots.forEach { $0.occluded = false }
            }
        }
    }

    /// Every mouse move wakes the app while a global monitor is installed, so it only exists while a playing
    /// wallpaper reacts to the pointer.
    func updatePointerTracking() {
        let wanted = prefs.pointerParallax && slots.contains { !$0.paused && $0.view?.session.scene.followsPointer == true }
        if wanted, mouseMonitor == nil {
            installMouseMonitor()
        } else if !wanted, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
            slots.forEach { $0.view?.setPointer(nil) }
        }
    }

    private func updateAudioCapture() {
        if prefs.audioReactive && slots.contains(where: { !$0.paused && $0.view != nil }) {
            Task { await AudioCapture.shared.start() }
        } else {
            AudioCapture.shared.stop()
        }
    }

    /// Occlusion notifications are unreliable for desktop-level windows, so coverage is also measured
    /// directly from the window list.
    private func updateCoverage() {
        guard prefs.pauseWhenCovered, !slots.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let windows: [CGRect] = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.9,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict) else { return nil }
            return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        var changed = false
        for slot in slots {
            let covered = Self.coveredFraction(of: slot.screen.visibleFrame, by: windows) >= 0.85 || !slot.window.occlusionState.contains(.visible)
            if covered != slot.occluded {
                slot.occluded = covered
                changed = true
            }
        }
        if changed { evaluatePolicy() }
    }

    private static func coveredFraction(of area: CGRect, by windows: [CGRect]) -> Double {
        let relevant = windows.filter { $0.intersects(area) }
        guard !relevant.isEmpty else { return 0 }
        let cols = 48, rows = 27
        var hits = 0
        for r in 0..<rows {
            for c in 0..<cols {
                let p = CGPoint(x: area.minX + area.width * (Double(c) + 0.5) / Double(cols),
                                y: area.minY + area.height * (Double(r) + 0.5) / Double(rows))
                if relevant.contains(where: { $0.contains(p) }) { hits += 1 }
            }
        }
        return Double(hits) / Double(cols * rows)
    }

    private func publish() {
        let next = slots.map { slot in
            DisplayInfo(
                id: slot.key,
                name: slot.screen.localizedName,
                size: slot.screen.frame.size,
                pixelSize: CGSize(width: slot.screen.frame.width * slot.screen.backingScaleFactor, height: slot.screen.frame.height * slot.screen.backingScaleFactor),
                wallpaperID: slot.wallpaperID,
                paused: slot.paused,
                recoveries: slot.totalRecoveries,
                lastRecovery: slot.lastRecovery
            )
        }
        if next != displays { displays = next }
    }

    // MARK: Freeze guard

    private func updateHealthTimer() {
        let wanted = slots.contains { $0.view != nil }
        if wanted, healthTimer == nil {
            healthTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHealth() }
            }
            healthTimer?.tolerance = 1
        } else if !wanted, let timer = healthTimer {
            timer.invalidate()
            healthTimer = nil
        }
    }

    /// Repairs a display whose wallpaper should be moving but isn't: a window left at a stale position, a video
    /// player that stopped, or a surface that stopped drawing. Two failed checks in a row count as a freeze, and a
    /// display that keeps freezing is left alone after three repairs in ten minutes so it can't loop.
    private func checkHealth() {
        let now = Date()
        for slot in slots where slot.view != nil {
            if let current = NSScreen.screens.first(where: { $0.stableKey == slot.key }) {
                slot.screen = current
                if !Self.same(slot.window.frame, current.frame) {
                    recovered(slot, "its window was at \(slot.window.frame), off the display at \(current.frame); moved it back", at: now)
                    slot.window.setFrame(current.frame, display: true)
                    slot.window.orderFrontRegardless()
                    continue
                }
            }
            guard !slot.paused, let view = slot.view, let stall = view.stall() else {
                slot.strikes = 0
                continue
            }
            slot.strikes += 1
            guard slot.strikes >= 2 else { continue }
            slot.strikes = 0
            slot.recoveries.removeAll { now.timeIntervalSince($0) > 600 }
            guard slot.recoveries.count < 3 else {
                if !slot.gaveUp {
                    slot.gaveUp = true
                    Log.shared.write("Freeze guard: \(slot.screen.localizedName) is still frozen (\(stall.rawValue)) after three repairs in ten minutes; leaving it")
                }
                continue
            }
            slot.recoveries.append(now)
            if stall == .clock, view.session.restartVideos() {
                recovered(slot, "\(stall.rawValue); restarted the video where it was", at: now)
            } else {
                recovered(slot, "\(stall.rawValue); rebuilt the wallpaper", at: now)
                show(assignment?(slot.key) ?? view.wallpaper, in: slot)
            }
        }
    }

    private func recovered(_ slot: Slot, _ what: String, at date: Date) {
        Log.shared.write("Freeze guard: \(slot.screen.localizedName) [\(slot.view?.wallpaper.title ?? "none")]: \(what)")
        slot.totalRecoveries += 1
        slot.gaveUp = false
        slot.lastRecovery = "\(date.formatted(date: .omitted, time: .shortened)): \(what.components(separatedBy: ";").first ?? what)"
        publish()
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    // MARK: Reactions

    /// Lets the wallpaper on `display` (or every display) react; displays showing one wallpaper share its session,
    /// so it reacts once.
    func react(_ trigger: ReactionTrigger, display: String? = nil, away: Double? = nil, force: Bool = false) {
        var done: Set<ObjectIdentifier> = []
        for slot in slots where display == nil || slot.key == display {
            guard force || !slot.paused, let session = slot.view?.session, done.insert(ObjectIdentifier(session)).inserted else { continue }
            session.react(trigger, away: away, force: force)
        }
    }

    private func showsReaction(to trigger: ReactionTrigger) -> Bool {
        slots.contains { slot in
            guard let session = slot.view?.session else { return false }
            return session.reactionsEnabled && session.scene.reactions?.rule(for: trigger) != nil
        }
    }

    /// The click monitor and the idle poll exist only while a wallpaper on screen uses them.
    private func updateReactionInputs() {
        let clicks = showsReaction(to: .click) && pauseReason == nil
        if clicks, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.desktopClicked(at: NSEvent.mouseLocation) }
            }
        } else if !clicks, let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        // Being away usually means locked or asleep, so the poll keeps running while wallpapers are paused.
        let away = showsReaction(to: .comeBack)
        if away, idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollIdle() }
            }
            idleTimer?.tolerance = 2
        } else if !away, let t = idleTimer {
            t.invalidate()
            idleTimer = nil
            peakIdle = 0
        }
    }

    private func pollIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < 4, peakIdle >= 10 {
            let away = peakIdle
            peakIdle = 0
            react(.comeBack, away: away)
        } else {
            peakIdle = max(peakIdle, idle)
        }
    }

    private func desktopClicked(at point: NSPoint) {
        guard let slot = slots.first(where: { NSMouseInRect(point, $0.screen.frame, false) }), !slot.paused else { return }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        guard DesktopHitTest.isDesktopExposed(at: CGPoint(x: point.x, y: primaryHeight - point.y)) else { return }
        react(.click, display: slot.key)
    }

    // MARK: Pointer

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
    }

    private func handleMouse() {
        guard prefs.pointerParallax else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMouse > 1.0 / 60 else { return }
        lastMouse = now
        let location = NSEvent.mouseLocation
        for slot in slots {
            let f = slot.screen.frame
            if NSMouseInRect(location, f, false), !slot.paused {
                let p = SIMD2<Float>(Float((location.x - f.minX) / f.width), Float((f.maxY - location.y) / f.height))
                slot.view?.setPointer(p)
            } else {
                slot.view?.setPointer(nil)
            }
        }
    }
}
