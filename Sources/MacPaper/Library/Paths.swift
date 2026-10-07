import Foundation

enum Paths {
    static let bundleID = "com.adilkairolla.macpaper"

    /// Read from the passwd entry: inside the screen saver's sandbox, FileManager's home is its container.
    static let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir), isDirectory: true)

    static let appSupport = ensure(home.appendingPathComponent("Library/Application Support/MacPaper", isDirectory: true))
    static let library = ensure(appSupport.appendingPathComponent("Library", isDirectory: true))
    static let cache = ensure(appSupport.appendingPathComponent("Cache", isDirectory: true))
    /// Posters rendered with the user's control values, so the first paint matches what plays.
    static let personalPosters = ensure(cache.appendingPathComponent("Posters", isDirectory: true))
    /// Posters rendered for packages that ship none.
    static let generatedPosters = ensure(cache.appendingPathComponent("Generated Posters", isDirectory: true))
    static let desktopPictures = ensure(appSupport.appendingPathComponent("Desktop Pictures", isDirectory: true))
    static let stateFile = appSupport.appendingPathComponent("state.json")
    static let preferencesPlist = home.appendingPathComponent("Library/Preferences/\(bundleID).plist")
    static let screenSavers = home.appendingPathComponent("Library/Screen Savers", isDirectory: true)

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Newest file modification inside a package, ignoring generated files like the poster.
    static func latestModification(_ url: URL, ignoring: Set<String> = []) -> Date {
        var latest = Date.distantPast
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return latest }
        for case let file as URL in e {
            if ignoring.contains(file.lastPathComponent) { continue }
            if let d = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > latest { latest = d }
        }
        return latest
    }
}
