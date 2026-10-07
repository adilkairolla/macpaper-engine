import AppKit
import CoreServices
import Observation

struct BrokenPackage: Identifiable, Hashable {
    var url: URL
    var message: String
    var id: URL { url }
}

/// The wallpapers on disk: packages in the library folder plus linked package folders elsewhere.
/// Watches both and reports packages whose files changed so they reload live.
@MainActor
@Observable
final class LibraryStore {
    private(set) var wallpapers: [Wallpaper] = []
    private(set) var broken: [BrokenPackage] = []
    private(set) var issues: [String: [Issue]] = [:]
    private(set) var validating: Set<String> = []
    private(set) var makingPoster: Set<String> = []

    @ObservationIgnored var onChange: ((_ changed: Set<String>, _ removed: Set<String>) -> Void)?
    @ObservationIgnored private(set) var linked: [URL]
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var validated: [String: Date] = [:]
    @ObservationIgnored private var savedResults = ValidationCache.load()

    init(linked: [String]) {
        self.linked = linked.map { URL(fileURLWithPath: $0, isDirectory: true) }
        scan()
        startWatching()
    }

    func wallpaper(id: String) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    func errors(for id: String) -> [Issue] {
        (issues[id] ?? []).filter { $0.severity == .error }
    }

    // MARK: Scanning

    func scan() {
        let (found, bad) = Self.read(linked: linked)
        let old = Dictionary(wallpapers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = Set(found.filter { w in old[w.id].map { $0.stamp != w.stamp || $0.url != w.url } ?? false }.map(\.id))
        let removed = Set(old.keys).subtracting(found.map(\.id))
        wallpapers = found
        broken = bad
        for id in removed { issues[id] = nil }
        for wp in found where validated[wp.id] != wp.stamp {
            if let saved = savedResults.entries[wp.id], saved.stamp == wp.stamp {
                validated[wp.id] = wp.stamp
                issues[wp.id] = saved.issues
            } else {
                validate(wp)
            }
        }
        if !changed.isEmpty || !removed.isEmpty { onChange?(changed, removed) }
        for wp in found where wp.needsGeneratedPoster && issues[wp.id].map({ $0.allSatisfy { $0.severity != .error } }) ?? true {
            makePoster(wp)
        }
    }

    /// Reads every package in the library folder plus the linked folders. Also used by the screen saver.
    nonisolated static func read(linked: [URL]) -> ([Wallpaper], [BrokenPackage]) {
        var found: [Wallpaper] = []
        var bad: [BrokenPackage] = []
        var seen: Set<String> = []
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: Paths.library, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let candidates = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map { ($0, false) }
            + linked.map { ($0, true) }
        for (url, isLinked) in candidates {
            guard fm.fileExists(atPath: url.appendingPathComponent(Manifest.fileName).path) else {
                if isLinked { bad.append(BrokenPackage(url: url, message: "\(Manifest.fileName) is missing")) }
                continue
            }
            do {
                let wp = try Wallpaper.load(url, linked: isLinked)
                if seen.contains(wp.id) {
                    bad.append(BrokenPackage(url: url, message: "has the same id as another wallpaper"))
                    continue
                }
                seen.insert(wp.id)
                found.append(wp)
            } catch {
                bad.append(BrokenPackage(url: url, message: "\(error)"))
            }
        }
        return (found, bad)
    }

    func validate(_ wp: Wallpaper) {
        validated[wp.id] = wp.stamp
        validating.insert(wp.id)
        Task {
            let result = await Validator.validate(wp)
            validating.remove(wp.id)
            guard wallpaper(id: wp.id)?.stamp == wp.stamp else { return }
            issues[wp.id] = result
            savedResults.entries[wp.id] = .init(stamp: wp.stamp, issues: result)
            savedResults.entries = savedResults.entries.filter { id, _ in wallpapers.contains { $0.id == id } }
            savedResults.save()
        }
    }

    func makePoster(_ wp: Wallpaper) {
        guard !makingPoster.contains(wp.id) else { return }
        makingPoster.insert(wp.id)
        Task {
            defer { makingPoster.remove(wp.id) }
            do {
                _ = try await PosterMaker.make(for: wp, to: wp.packagePosterURL == nil ? wp.generatedPosterURL : nil)
                PosterCache.shared.invalidate(wp.id)
                scan()
            } catch {
                Log.shared.write("Poster for \(wp.title) failed: \(error)")
            }
        }
    }

    // MARK: Changes

    /// The library copy a package would replace: same id, somewhere else.
    func existing(for incoming: Wallpaper, at url: URL) -> Wallpaper? {
        wallpaper(id: incoming.id).flatMap { $0.url.standardizedFileURL == url.standardizedFileURL ? nil : $0 }
    }

    /// Copies (or moves) a package into the library off the main thread. It is staged outside the watched
    /// library folder, and an existing copy with the same id only goes to the Trash once the new one is complete.
    func importPackage(at url: URL, move: Bool = false) async throws -> Wallpaper {
        let incoming = try Wallpaper.load(url)
        let replacing = existing(for: incoming, at: url)
        if wallpaper(id: incoming.id)?.url.standardizedFileURL == url.standardizedFileURL { return incoming }
        if let replacing, replacing.linked {
            throw ImportError(message: "\(incoming.title) is already in your library as a folder edited in place (\(replacing.url.path)). Remove that one first.")
        }
        var name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = incoming.title }
        let target = replacing?.url
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = Paths.ensure(Paths.cache.appendingPathComponent("Importing/\(UUID().uuidString)", isDirectory: true))
            defer { try? fm.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(name).appendingPathExtension(Manifest.packageExtension)
            if move { try fm.moveItem(at: url, to: staged) } else { try fm.copyItem(at: url, to: staged) }
            if let target {
                try fm.trashItem(at: target, resultingItemURL: nil)
                try fm.moveItem(at: staged, to: target)
            } else {
                var dest = Paths.library.appendingPathComponent(name).appendingPathExtension(Manifest.packageExtension)
                var n = 2
                while fm.fileExists(atPath: dest.path) {
                    dest = Paths.library.appendingPathComponent("\(name) \(n)").appendingPathExtension(Manifest.packageExtension)
                    n += 1
                }
                try fm.moveItem(at: staged, to: dest)
            }
        }.value
        scan()
        return wallpaper(id: incoming.id) ?? incoming
    }

    /// Adds a package folder in place; edits to it show up live. Ideal for authoring with an AI or editor.
    @discardableResult
    func link(_ url: URL) throws -> Wallpaper {
        let url = url.standardizedFileURL
        let wp = try Wallpaper.load(url, linked: true)
        if let other = wallpaper(id: wp.id), other.url.standardizedFileURL != url {
            throw ImportError(message: "\(wp.title) is already in your library. Remove it before adding this folder.")
        }
        if !linked.contains(where: { $0.standardizedFileURL == url }) { linked.append(url) }
        startWatching()
        scan()
        return wallpaper(id: wp.id) ?? wp
    }

    /// Where a removed wallpaper went, so it can be put back.
    enum Removal {
        case unlinked(URL)
        case trashed(original: URL, trash: URL)
    }

    func isLinked(_ url: URL) -> Bool {
        linked.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func delete(_ wp: Wallpaper) throws -> Removal {
        try remove(wp.url)
    }

    /// Unlinks a folder used in place, or moves a library package to the Trash.
    func remove(_ url: URL) throws -> Removal {
        defer { scan() }
        if isLinked(url) {
            linked.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
            startWatching()
            return .unlinked(url)
        }
        var trash: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trash)
        return .trashed(original: url, trash: (trash as URL?) ?? url)
    }

    func restore(_ removal: Removal) throws {
        switch removal {
        case .unlinked(let url):
            if !isLinked(url) { linked.append(url) }
            startWatching()
        case .trashed(let original, let trash):
            try FileManager.default.moveItem(at: trash, to: original)
        }
        scan()
    }

    var linkedPaths: [String] { linked.map(\.path) }

    private func startWatching() {
        let paths = [Paths.library.path] + linked.map(\.path)
        watcher = FileWatcher(paths: paths) { [weak self] in
            self?.scheduleScan()
        }
    }

    @ObservationIgnored private var pendingScan: DispatchWorkItem?

    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

struct ImportError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Validation results from earlier launches; a new build of the app invalidates them all, since its checks may differ.
struct ValidationCache: Codable {
    struct Entry: Codable { var stamp: Date; var issues: [Issue] }
    var build: Date
    var entries: [String: Entry] = [:]

    private static let url = Paths.cache.appendingPathComponent("validation.json")

    private static var currentBuild: Date {
        Bundle.main.executableURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } ?? .distantPast
    }

    static func load() -> ValidationCache {
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(ValidationCache.self, from: data),
              cache.build == currentBuild else { return ValidationCache(build: currentBuild) }
        return cache
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// FSEvents on a set of folders, delivered on the main queue.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor () -> Void

    init(paths: [String], handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.handler() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        stream = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
