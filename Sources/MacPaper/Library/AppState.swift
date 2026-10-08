import Foundation

struct CycleSetting: Codable, Hashable {
    var minutes = 0
    var shuffle = false
    /// Advance whenever the wallpaper's video reaches its end instead of on a timer.
    var afterClip = false
    /// Option values left out of the rotation.
    var skip: [JSONValue] = []

    init(minutes: Int = 0, shuffle: Bool = false, afterClip: Bool = false, skip: [JSONValue] = []) {
        self.minutes = minutes
        self.shuffle = shuffle
        self.afterClip = afterClip
        self.skip = skip
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 0
        shuffle = (try? c.decode(Bool.self, forKey: .shuffle)) ?? false
        afterClip = (try? c.decode(Bool.self, forKey: .afterClip)) ?? false
        skip = (try? c.decode([JSONValue].self, forKey: .skip)) ?? []
    }

    var isOff: Bool { minutes <= 0 && !afterClip }

    /// The option after `current` in the rotation, in manifest order unless shuffled.
    func next(after current: JSONValue?, in control: Control) -> JSONValue? {
        let index = control.options.firstIndex { $0.value == current } ?? 0
        let included = control.options.indices.filter { !skip.contains(control.options[$0].value) }
        guard !included.isEmpty else { return nil }
        let next = shuffle
            ? included.filter { $0 != index }.randomElement() ?? index
            : included.first { $0 > index } ?? included[0]
        return control.options[next].value
    }
}

/// A named set of wallpapers that the desktop or the screen saver plays one after another.
struct Playlist: Codable, Hashable, Identifiable {
    /// How long a wallpaper without video stays when the playlist plays each one once through.
    static let stillMinutes = 5
    /// Once through, a short loop repeats until this many seconds have passed, then moves on at a loop point.
    static let onceThroughMinimum: TimeInterval = 180

    var id = UUID()
    var name: String
    var wallpaperIDs: [String] = []
    var shuffle = false
    /// 0 plays each wallpaper once through: until its video ends (repeating a short loop for at least
    /// `onceThroughMinimum`), or `stillMinutes` when it has none.
    var minutes = 0

    init(name: String, wallpaperIDs: [String] = []) {
        self.name = name
        self.wallpaperIDs = wallpaperIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Playlist"
        wallpaperIDs = (try? c.decode([String].self, forKey: .wallpaperIDs)) ?? []
        shuffle = (try? c.decode(Bool.self, forKey: .shuffle)) ?? false
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 0
    }

    /// The wallpaper to play after `current`, skipping ones not in `available`; with no current, where it starts.
    func next(after current: String?, available: Set<String>) -> String? {
        let ids = wallpaperIDs.filter(available.contains)
        guard !ids.isEmpty else { return nil }
        if shuffle { return ids.filter { $0 != current }.randomElement() ?? ids[0] }
        let start = current.flatMap(wallpaperIDs.firstIndex(of:)) ?? -1
        for step in 1...wallpaperIDs.count {
            let id = wallpaperIDs[(start + step) % wallpaperIDs.count]
            if available.contains(id) { return id }
        }
        return ids[0]
    }
}

struct Preset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var values: [String: JSONValue]
}

/// Everything the user chose for one wallpaper. Lives in the app, never in the package.
struct WallpaperSettings: Codable, Equatable {
    var values: [String: JSONValue] = [:]
    var focus: [String: [Double]] = [:]
    /// Fit the whole canvas inside the display, with bars, instead of filling it.
    var showAll = false
    /// One picture across every display, laid out like the displays are arranged.
    var span = false
    /// Plays the wallpaper's reaction clips when something happens.
    var reactions = true
    /// For wallpapers with a resting loop: alternate, rest only, or show only.
    var restMode = RestMode.cycle
    var speed: Double = 1
    var fpsCap: Int = 0
    var brightness: Double = 1
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0
    var parallax: Double = 1
    var volume: Double = 0.8
    var muted: Bool = true
    var cycles: [String: CycleSetting] = [:]
    var presets: [Preset] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperSettings()
        values = (try? c.decode([String: JSONValue].self, forKey: .values)) ?? d.values
        focus = (try? c.decode([String: [Double]].self, forKey: .focus)) ?? d.focus
        showAll = (try? c.decode(Bool.self, forKey: .showAll)) ?? d.showAll
        span = (try? c.decode(Bool.self, forKey: .span)) ?? d.span
        reactions = (try? c.decode(Bool.self, forKey: .reactions)) ?? d.reactions
        restMode = (try? c.decode(RestMode.self, forKey: .restMode)) ?? d.restMode
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? d.speed
        fpsCap = (try? c.decode(Int.self, forKey: .fpsCap)) ?? d.fpsCap
        brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? d.brightness
        contrast = (try? c.decode(Double.self, forKey: .contrast)) ?? d.contrast
        saturation = (try? c.decode(Double.self, forKey: .saturation)) ?? d.saturation
        warmth = (try? c.decode(Double.self, forKey: .warmth)) ?? d.warmth
        parallax = (try? c.decode(Double.self, forKey: .parallax)) ?? d.parallax
        volume = (try? c.decode(Double.self, forKey: .volume)) ?? d.volume
        muted = (try? c.decode(Bool.self, forKey: .muted)) ?? d.muted
        cycles = (try? c.decode([String: CycleSetting].self, forKey: .cycles)) ?? d.cycles
        presets = (try? c.decode([Preset].self, forKey: .presets)) ?? d.presets
    }

    var grade: GradeUniforms {
        GradeUniforms(brightness: Float(brightness), contrast: Float(contrast), saturation: Float(saturation), warmth: Float(warmth))
    }

    var hasDisplayChanges: Bool {
        speed != 1 || fpsCap != 0 || brightness != 1 || contrast != 1 || saturation != 1 || warmth != 0 || parallax != 1 || !focus.isEmpty || showAll || span
    }

    /// The package's suggested rotations with the user's own choices on top; "Never" is stored, so it wins.
    func cycles(for manifest: Manifest) -> [String: CycleSetting] {
        var out: [String: CycleSetting] = [:]
        for control in manifest.allControls where control.kind == .choice {
            switch control.cycle {
            case .string("clip"): out[control.id] = CycleSetting(afterClip: true)
            case .number(let m) where m > 0: out[control.id] = CycleSetting(minutes: Int(min(m, 10080).rounded(.up)))
            default: break
            }
        }
        out.merge(cycles) { _, mine in mine }
        return out.filter { !$0.value.isOff }
    }

    func focus(for display: String) -> SIMD2<Double>? {
        guard let f = focus[display] ?? focus[AppState.allDisplaysKey], f.count == 2 else { return nil }
        return SIMD2(f[0], f[1])
    }
}

struct AppState: Codable {
    static let allDisplaysKey = "*"

    var assignments: [String: String] = [:]
    var wallpapers: [String: WallpaperSettings] = [:]
    var favorites: Set<String> = []
    var recents: [String] = []
    var linked: [String] = []
    var added: [String: Date] = [:]
    var playlists: [Playlist] = []
    /// The playlist playing on each display, keyed like `assignments`; an empty id marks a display that stopped one.
    var playing: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assignments = (try? c.decode([String: String].self, forKey: .assignments)) ?? [:]
        wallpapers = (try? c.decode([String: WallpaperSettings].self, forKey: .wallpapers)) ?? [:]
        favorites = (try? c.decode(Set<String>.self, forKey: .favorites)) ?? []
        recents = (try? c.decode([String].self, forKey: .recents)) ?? []
        linked = (try? c.decode([String].self, forKey: .linked)) ?? []
        added = (try? c.decode([String: Date].self, forKey: .added)) ?? [:]
        playlists = (try? c.decode([Playlist].self, forKey: .playlists)) ?? []
        playing = (try? c.decode([String: String].self, forKey: .playing)) ?? [:]
    }

    /// An empty id marks a display the user cleared, so it doesn't fall back to the all-displays choice.
    func wallpaperID(forDisplay key: String, perDisplay: Bool) -> String? {
        let id = perDisplay ? (assignments[key] ?? assignments[Self.allDisplaysKey]) : assignments[Self.allDisplaysKey]
        return id?.isEmpty == false ? id : nil
    }

    func playlist(forDisplay key: String, perDisplay: Bool) -> Playlist? {
        let id = perDisplay ? (playing[key] ?? playing[Self.allDisplaysKey]) : playing[Self.allDisplaysKey]
        guard let id, !id.isEmpty else { return nil }
        return playlists.first { $0.id.uuidString == id }
    }

    func playlist(_ id: UUID?) -> Playlist? {
        playlists.first { $0.id == id }
    }

    func settings(_ id: String) -> WallpaperSettings {
        wallpapers[id] ?? WallpaperSettings()
    }

    static func load() -> AppState {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else { return AppState() }
        return state
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.stateFile, options: .atomic)
    }
}
