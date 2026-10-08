import AppKit
import IOKit.ps
import Observation

/// Tracks the machine state that playback policy depends on.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var onBattery = false
    private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var screensAsleep = false
    private(set) var screenLocked = false
    private(set) var frontmostIsOther = false
    private(set) var screenSaverRunning = false
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Moments a wallpaper's character can react to.
    @ObservationIgnored var onReactionEvent: ((ReactionTrigger) -> Void)?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var playersPlaying: Set<String> = []
    @ObservationIgnored private var musicStoppedAt: Date?

    init() {
        onBattery = Self.readOnBattery()
        updateFrontmost()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { monitor.updatePowerSource() } }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = false
                self?.onReactionEvent?(.wake)
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrontmost() }
        })
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = false
                self?.onReactionEvent?(.unlock)
            }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenSaverRunning = true }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenSaverRunning = false }
        })
        for (name, player) in [("com.apple.Music.playerInfo", "music"), ("com.spotify.client.PlaybackStateChanged", "spotify")] {
            observers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let playing = note.userInfo?["Player State"] as? String == "Playing"
                MainActor.assumeIsolated { self?.player(player, playing: playing) }
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
    }

    private func updatePowerSource() {
        let was = onBattery
        onBattery = Self.readOnBattery()
        if was, !onBattery { onReactionEvent?(.charge) }
    }

    /// Music starting after a pause of at least a minute; skipping tracks or a short pause doesn't count.
    private func player(_ name: String, playing: Bool) {
        let wasSilent = playersPlaying.isEmpty
        if playing { playersPlaying.insert(name) } else { playersPlaying.remove(name) }
        if playersPlaying.isEmpty, !wasSilent { musicStoppedAt = Date() }
        if wasSilent, !playersPlaying.isEmpty, musicStoppedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            onReactionEvent?(.music)
        }
    }

    private func updateFrontmost() {
        let app = NSWorkspace.shared.frontmostApplication
        let ignored = [Bundle.main.bundleIdentifier, "com.apple.finder", "com.apple.dock", "com.apple.loginwindow"]
        frontmostIsOther = !ignored.contains(app?.bundleIdentifier)
    }

    nonisolated static func readOnBattery() -> Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
