import Foundation
import Observation

enum FocusBehavior: String, CaseIterable, Identifiable {
    case keepRunning, mute, pause
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keepRunning: "Keep running"
        case .mute: "Mute audio"
        case .pause: "Pause"
        }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case native, balanced, efficient
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: "Native"
        case .balanced: "Balanced"
        case .efficient: "Efficient"
        }
    }
    var detail: String {
        switch self {
        case .native: "Everything renders at your display’s full resolution."
        case .balanced: "Shader effects render at 75% and are sharpened back up — indistinguishable on most wallpapers."
        case .efficient: "Shader effects render at half resolution and are sharpened back up. Best for battery."
        }
    }
    var renderScale: Double {
        switch self {
        case .native: 1
        case .balanced: 0.75
        case .efficient: 0.5
        }
    }
}

enum ShuffleSource: String, CaseIterable, Identifiable {
    case favorites, library
    var id: String { rawValue }
    var title: String { self == .favorites ? "Favorites" : "Entire library" }
}

enum ScreenSaverSource: String, CaseIterable, Identifiable {
    case desktop, wallpaper, favorites, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktop: "Current desktop wallpaper"
        case .wallpaper: "A specific wallpaper"
        case .favorites: "Shuffle favorites"
        case .library: "Shuffle entire library"
        }
    }
}

/// App-wide settings. Stored in the app's defaults domain, which the screen saver reads from disk.
@MainActor
@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var pauseWhenCovered: Bool { didSet { defaults.set(pauseWhenCovered, forKey: "pauseWhenCovered") } }
    var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: "pauseOnBattery") } }
    var pauseInLowPowerMode: Bool { didSet { defaults.set(pauseInLowPowerMode, forKey: "pauseInLowPowerMode") } }
    var pauseWithReduceMotion: Bool { didSet { defaults.set(pauseWithReduceMotion, forKey: "pauseWithReduceMotion") } }
    var focusBehavior: FocusBehavior { didSet { defaults.set(focusBehavior.rawValue, forKey: "focusBehavior") } }
    var frameRateCap: Int { didSet { defaults.set(frameRateCap, forKey: "frameRateCap") } }
    var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    var batteryQuality: Quality { didSet { defaults.set(batteryQuality.rawValue, forKey: "batteryQuality") } }
    var pointerParallax: Bool { didSet { defaults.set(pointerParallax, forKey: "pointerParallax") } }
    var audioReactive: Bool { didSet { defaults.set(audioReactive, forKey: "audioReactive") } }
    var syncDesktopPicture: Bool { didSet { defaults.set(syncDesktopPicture, forKey: "syncDesktopPicture") } }
    var masterVolume: Double { didSet { defaults.set(masterVolume, forKey: "masterVolume") } }
    var globalMute: Bool { didSet { defaults.set(globalMute, forKey: "globalMute") } }
    var shuffleMinutes: Int { didSet { defaults.set(shuffleMinutes, forKey: "shuffleMinutes") } }
    var shuffleSource: ShuffleSource { didSet { defaults.set(shuffleSource.rawValue, forKey: "shuffleSource") } }
    var perDisplay: Bool { didSet { defaults.set(perDisplay, forKey: "perDisplay") } }
    var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: "showDockIcon") } }
    var transitionSeconds: Double { didSet { defaults.set(transitionSeconds, forKey: "transitionSeconds") } }
    var saverSource: ScreenSaverSource { didSet { defaults.set(saverSource.rawValue, forKey: "saverSource") } }
    var saverWallpaperID: String { didSet { defaults.set(saverWallpaperID, forKey: "saverWallpaperID") } }
    var saverRotateMinutes: Int { didSet { defaults.set(saverRotateMinutes, forKey: "saverRotateMinutes") } }
    var saverSound: Bool { didSet { defaults.set(saverSound, forKey: "saverSound") } }

    init() {
        defaults.register(defaults: [
            "pauseWhenCovered": true,
            "pauseOnBattery": false,
            "pauseInLowPowerMode": true,
            "pauseWithReduceMotion": true,
            "focusBehavior": FocusBehavior.keepRunning.rawValue,
            "frameRateCap": 0,
            "quality": Quality.native.rawValue,
            "batteryQuality": Quality.balanced.rawValue,
            "pointerParallax": true,
            "audioReactive": false,
            "syncDesktopPicture": true,
            "masterVolume": 1.0,
            "globalMute": false,
            "shuffleMinutes": 0,
            "shuffleSource": ShuffleSource.favorites.rawValue,
            "perDisplay": false,
            "showDockIcon": true,
            "transitionSeconds": 0.35,
            "saverSource": ScreenSaverSource.desktop.rawValue,
            "saverWallpaperID": "",
            "saverRotateMinutes": 10,
            "saverSound": false,
        ])
        pauseWhenCovered = defaults.bool(forKey: "pauseWhenCovered")
        pauseOnBattery = defaults.bool(forKey: "pauseOnBattery")
        pauseInLowPowerMode = defaults.bool(forKey: "pauseInLowPowerMode")
        pauseWithReduceMotion = defaults.bool(forKey: "pauseWithReduceMotion")
        focusBehavior = FocusBehavior(rawValue: defaults.string(forKey: "focusBehavior") ?? "") ?? .keepRunning
        frameRateCap = defaults.integer(forKey: "frameRateCap")
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .native
        batteryQuality = Quality(rawValue: defaults.string(forKey: "batteryQuality") ?? "") ?? .balanced
        pointerParallax = defaults.bool(forKey: "pointerParallax")
        audioReactive = defaults.bool(forKey: "audioReactive")
        syncDesktopPicture = defaults.bool(forKey: "syncDesktopPicture")
        masterVolume = defaults.double(forKey: "masterVolume")
        globalMute = defaults.bool(forKey: "globalMute")
        shuffleMinutes = defaults.integer(forKey: "shuffleMinutes")
        shuffleSource = ShuffleSource(rawValue: defaults.string(forKey: "shuffleSource") ?? "") ?? .favorites
        perDisplay = defaults.bool(forKey: "perDisplay")
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        transitionSeconds = defaults.double(forKey: "transitionSeconds")
        saverSource = ScreenSaverSource(rawValue: defaults.string(forKey: "saverSource") ?? "") ?? .desktop
        saverWallpaperID = defaults.string(forKey: "saverWallpaperID") ?? ""
        saverRotateMinutes = defaults.integer(forKey: "saverRotateMinutes")
        saverSound = defaults.bool(forKey: "saverSound")
    }
}

/// The saver runs sandboxed inside legacyScreenSaver, where UserDefaults can't reach the app's domain,
/// so it reads the preferences plist from disk.
struct SaverPreferences {
    var source = ScreenSaverSource.desktop
    var wallpaperID: String?
    var rotateMinutes = 10
    var sound = false
    var perDisplay = false
    var frameRateCap = 0
    var quality = Quality.native

    static func load() -> SaverPreferences {
        let dict = NSDictionary(contentsOf: Paths.preferencesPlist) as? [String: Any] ?? [:]
        var s = SaverPreferences()
        if let v = (dict["saverSource"] as? String).flatMap(ScreenSaverSource.init) { s.source = v }
        if let v = dict["saverWallpaperID"] as? String, !v.isEmpty { s.wallpaperID = v }
        if let v = dict["saverRotateMinutes"] as? Int { s.rotateMinutes = v }
        if let v = dict["saverSound"] as? Bool { s.sound = v }
        if let v = dict["perDisplay"] as? Bool { s.perDisplay = v }
        if let v = dict["frameRateCap"] as? Int { s.frameRateCap = v }
        if let v = (dict["quality"] as? String).flatMap(Quality.init) { s.quality = v }
        return s
    }
}
