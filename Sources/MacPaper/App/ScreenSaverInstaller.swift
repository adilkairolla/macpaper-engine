import AppKit
import Observation

@MainActor
@Observable
final class ScreenSaverInstaller {
    enum Status { case unavailable, notInstalled, outdated, installed }

    private(set) var status = Status.notInstalled
    private(set) var isSelected = false
    private(set) var lastError: String?

    @ObservationIgnored private let bundled = Bundle.main.url(forResource: "MacPaper", withExtension: "saver")
    @ObservationIgnored private let installed = Paths.screenSavers.appendingPathComponent("MacPaper.saver", isDirectory: true)
    @ObservationIgnored private let wallpaperStore = Paths.home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    init() {
        refresh()
        if status == .outdated { install() }
    }

    func refresh() {
        if bundled == nil {
            status = .unavailable
        } else if !FileManager.default.fileExists(atPath: installed.path) {
            status = .notInstalled
        } else {
            status = Self.version(of: installed) == bundled.flatMap(Self.version) ? .installed : .outdated
        }
        isSelected = Self.storeSelectsMacPaper(wallpaperStore)
    }

    func install() {
        guard let bundled else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Paths.screenSavers, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
            try fm.copyItem(at: bundled, to: installed)
            lastError = nil
            reloadScreenSaverHost()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        try? FileManager.default.trashItem(at: installed, resultingItemURL: nil)
        reloadScreenSaverHost()
        refresh()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
    }

    func startNow() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"), configuration: .init())
    }

    /// legacyScreenSaver keeps loaded bundles in memory; restarting it picks up the new build.
    private func reloadScreenSaverHost() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["-q", "legacyScreenSaver"]
        try? task.run()
    }

    private static func version(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    /// The idle (screen saver) choice lives in the wallpaper store as an encoded configuration that names the module.
    private static func storeSelectsMacPaper(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        var idles: [[String: Any]] = []
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if let entry = store[key] as? [String: Any], let idle = entry["Idle"] as? [String: Any] { idles.append(idle) }
        }
        for group in ["Displays", "Spaces"] {
            for case let entry as [String: Any] in (store[group] as? [String: Any])?.values.map({ $0 }) ?? [] {
                if let idle = entry["Idle"] as? [String: Any] { idles.append(idle) }
            }
        }
        return idles.contains { idle in
            let choices = (idle["Content"] as? [String: Any])?["Choices"] as? [[String: Any]] ?? []
            return choices.contains { choice in
                guard let config = choice["Configuration"] as? Data else { return false }
                return config.range(of: Data("MacPaper".utf8)) != nil
            }
        }
    }
}
