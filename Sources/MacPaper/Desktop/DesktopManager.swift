import AppKit
import Observation

struct DisplayInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let size: CGSize
    let pixelSize: CGSize
    var wallpaperID: String?
    var paused: Bool
}

/// One borderless window per screen at desktop level, each hosting a WallpaperView.
@MainActor
@Observable
final class DesktopManager {
    @MainActor
    private final class Slot {
        let key: String
        let screen: NSScreen
        let window: DesktopWindow
        let stage = NSView()
        var view: WallpaperView?
        var outgoing: WallpaperView?
        var wallpaperID: String?
        var occluded = false
        var paused = false
        var observer: NSObjectProtocol?

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
        trackPolicyInputs()
    }

    // MARK: Screens

    func rebuildScreens() {
        let screens = NSScreen.screens
        for slot in slots where !screens.contains(where: { $0 == slot.screen }) {
            teardown(slot)
        }
        slots.removeAll { slot in !screens.contains { $0 == slot.screen } }
        for screen in screens where !slots.contains(where: { $0.screen == screen }) {
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
        publish()
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
                paused: slot.paused
            )
        }
        if next != displays { displays = next }
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
