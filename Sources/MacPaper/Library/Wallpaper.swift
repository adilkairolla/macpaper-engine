import Foundation

struct Wallpaper: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case video, scene, shader, image

        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .video: "film"
            case .scene: "square.3.layers.3d"
            case .shader: "wand.and.stars"
            case .image: "photo"
            }
        }
    }

    let id: String
    let url: URL
    let manifest: Manifest
    let stamp: Date
    let linked: Bool
    /// The package's own poster, or one MacPaper rendered for a package that ships none.
    private(set) var posterURL: URL?
    /// When the poster last changed; posters don't count toward `stamp`, so thumbnails watch this instead.
    private(set) var posterStamp = Date.distantPast

    var title: String { manifest.title.text }

    var kind: Kind {
        let types = Set(manifest.layers.compactMap { $0["type"]?.string })
        if types == ["video"] { return .video }
        if types == ["shader"] { return .shader }
        if types == ["image"] { return .image }
        return .scene
    }

    var hasVideo: Bool { manifest.layers.contains { $0["type"]?.string == "video" } }

    init(id: String, url: URL, manifest: Manifest, stamp: Date, linked: Bool) {
        self.id = id
        self.url = url
        self.manifest = manifest
        self.stamp = stamp
        self.linked = linked
        findPoster()
    }

    /// The package's own poster file, if it ships one.
    var packagePosterURL: URL? {
        let candidates = [manifest.poster, "poster.heic", "poster.jpg", "poster.png"].compactMap { $0 }
        return candidates.lazy.compactMap { file($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where MacPaper keeps the poster it renders for a package without one; it never writes into the package.
    var generatedPosterURL: URL { Paths.generatedPosters.appendingPathComponent("\(id).heic") }

    /// A generated poster older than the package's files shows a look the wallpaper no longer has.
    var needsGeneratedPoster: Bool { packagePosterURL == nil && posterURL == nil }

    private mutating func findPoster() {
        if let own = packagePosterURL {
            posterURL = own
        } else if let d = Self.modified(generatedPosterURL), d >= stamp {
            posterURL = generatedPosterURL
        } else {
            posterURL = nil
        }
        posterStamp = posterURL.flatMap(Self.modified) ?? .distantPast
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    var personalPosterURL: URL { Paths.personalPosters.appendingPathComponent("\(id).heic") }

    /// The poster to show first: the user's personal one when their control values differ from the defaults.
    var effectivePosterURL: URL? {
        let personal = personalPosterURL
        if let d = Self.modified(personal), d >= stamp { return personal }
        return posterURL
    }

    /// Resolves a manifest path, refusing anything that escapes the package. The check is lexical: comparing
    /// standardized file URLs breaks for files that don't exist yet, since macOS only strips /private from real paths.
    func file(_ relative: String) -> URL? {
        guard !relative.hasPrefix("/") else { return nil }
        var depth = 0
        for part in relative.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            depth += part == ".." ? -1 : 1
            if depth < 0 { return nil }
        }
        guard depth > 0 else { return nil }
        return url.appendingPathComponent(relative).standardized
    }

    static func == (a: Wallpaper, b: Wallpaper) -> Bool {
        a.id == b.id && a.stamp == b.stamp && a.url == b.url && a.posterStamp == b.posterStamp
    }

    func hash(into h: inout Hasher) {
        h.combine(id)
        h.combine(stamp)
    }

    static func load(_ url: URL, linked: Bool = false) throws -> Wallpaper {
        let manifest = try Manifest.load(from: url)
        let generated: Set<String> = [manifest.poster.map { ($0 as NSString).lastPathComponent } ?? "poster.heic", "poster.heic"]
        return Wallpaper(id: manifest.id, url: url, manifest: manifest, stamp: Paths.latestModification(url, ignoring: generated), linked: linked)
    }
}
