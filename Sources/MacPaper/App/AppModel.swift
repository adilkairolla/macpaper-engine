import AppKit
import AVFoundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    let prefs = Preferences()
    let monitor = SystemMonitor()
    let library: LibraryStore
    let desktop: DesktopManager
    let screenSaver = ScreenSaverInstaller()
    let creator: Creator

    private(set) var state: AppState

    @ObservationIgnored private var shuffleTimer: Timer?
    @ObservationIgnored private var cycleTimers: [String: Timer] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init() {
        let state = AppState.load()
        self.state = state
        library = LibraryStore(linked: state.linked)
        desktop = DesktopManager(prefs: prefs, monitor: monitor)
        creator = Creator()
        desktop.assignment = { [unowned self] key in self.wallpaper(forDisplay: key) }
        desktop.values = { [unowned self] wp in self.state.settings(wp.id).values }
        desktop.settings = { [unowned self] wp, key in self.renderSettings(wp, display: key) }
        library.onChange = { [weak self] changed, removed in self?.libraryChanged(changed, removed) }
        creator.onCreated = { [weak self] url in try await self?.created(url) }
        observeShuffle()
        observeDesktopPictureSync()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDesktopPictures() }
        }
        NotificationCenter.default.addObserver(forName: SceneSession.clipEnded, object: nil, queue: nil) { [weak self] n in
            guard let session = n.object as? SceneSession else { return }
            MainActor.assumeIsolated { self?.clipEnded(wallpaperID: session.wallpaper.id) }
        }
    }

    func start() {
        Task { await installSamplesIfNeeded() }
        desktop.rebuildScreens()
        rescheduleShuffle()
        rescheduleCycles()
        syncDesktopPictures()
        for (id, s) in state.wallpapers where !s.values.isEmpty {
            if let wp = library.wallpaper(id: id), wp.effectivePosterURL != wp.personalPosterURL { schedulePersonalPoster(wp) }
        }
    }

    // MARK: Assignments

    func wallpaper(forDisplay key: String) -> Wallpaper? {
        guard let id = state.wallpaperID(forDisplay: key, perDisplay: prefs.perDisplay) else { return nil }
        return library.wallpaper(id: id)
    }

    var activeWallpaperIDs: Set<String> { Set(desktop.displays.compactMap(\.wallpaperID)) }

    var currentWallpaper: Wallpaper? {
        desktop.displays.first?.wallpaperID.flatMap { library.wallpaper(id: $0) }
    }

    var sortedWallpapers: [Wallpaper] {
        library.wallpapers.sorted { a, b in
            let da = state.added[a.id] ?? .distantPast, db = state.added[b.id] ?? .distantPast
            return da != db ? da > db : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Where an apply lands. With different wallpapers per display, the default is the screen being worked on.
    enum ApplyTarget: Equatable {
        case automatic, everywhere
        case display(String)
    }

    var focusedDisplayKey: String? { (NSApp.keyWindow?.screen ?? NSScreen.main)?.stableKey }

    var showsPerDisplayChoices: Bool { desktop.displays.count > 1 }

    func canApply(_ wallpaper: Wallpaper) -> Bool { library.errors(for: wallpaper.id).isEmpty }

    func isApplied(_ wallpaper: Wallpaper, to target: ApplyTarget = .automatic) -> Bool {
        switch resolved(target) {
        case .display(let key): desktop.displays.first { $0.id == key }?.wallpaperID == wallpaper.id
        default: !desktop.displays.isEmpty && desktop.displays.allSatisfy { $0.wallpaperID == wallpaper.id }
        }
    }

    private func resolved(_ target: ApplyTarget) -> ApplyTarget {
        guard target == .automatic else { return target }
        guard prefs.perDisplay, desktop.displays.count > 1, let key = focusedDisplayKey else { return .everywhere }
        return .display(key)
    }

    func apply(_ wallpaper: Wallpaper, to target: ApplyTarget = .automatic) {
        guard canApply(wallpaper) else {
            showToast("“\(wallpaper.title)” can’t play until its problems are fixed.")
            return
        }
        let before = snapshotAssignments()
        switch resolved(target) {
        case .display(let key):
            if !prefs.perDisplay { spreadToDisplays() }
            state.assignments[key] = wallpaper.id
        default:
            state.assignments = [AppState.allDisplaysKey: wallpaper.id]
        }
        state.recents.removeAll { $0 == wallpaper.id }
        state.recents.insert(wallpaper.id, at: 0)
        state.recents = Array(state.recents.prefix(24))
        commitAssignments(undo: before, name: "Apply “\(wallpaper.title)”")
    }

    func clear(display: String? = nil) {
        let before = snapshotAssignments()
        if let display, prefs.perDisplay {
            state.assignments[display] = ""
        } else {
            state.assignments.removeAll()
        }
        commitAssignments(undo: before, name: "Remove Wallpaper")
    }

    func setPerDisplay(_ on: Bool) {
        let before = snapshotAssignments()
        if on {
            spreadToDisplays()
        } else if let first = desktop.displays.first?.wallpaperID {
            state.assignments = [AppState.allDisplaysKey: first]
            prefs.perDisplay = false
        } else {
            prefs.perDisplay = false
        }
        commitAssignments(undo: before, name: on ? "Different Wallpaper per Display" : "Same Wallpaper Everywhere")
    }

    /// Every display keeps what it shows now, as its own choice.
    private func spreadToDisplays() {
        if let all = state.assignments[AppState.allDisplaysKey] {
            for d in desktop.displays where state.assignments[d.id] == nil { state.assignments[d.id] = all }
        }
        prefs.perDisplay = true
    }

    private typealias AssignmentSnapshot = (assignments: [String: String], perDisplay: Bool)

    private func snapshotAssignments() -> AssignmentSnapshot { (state.assignments, prefs.perDisplay) }

    private func commitAssignments(undo before: AssignmentSnapshot, name: String) {
        save()
        desktop.reloadAssignments()
        rescheduleCycles()
        syncDesktopPictures()
        guard before.assignments != state.assignments || before.perDisplay != prefs.perDisplay else { return }
        registerUndo(name) { model in
            let redo = model.snapshotAssignments()
            model.state.assignments = before.assignments
            model.prefs.perDisplay = before.perDisplay
            model.commitAssignments(undo: redo, name: name)
        }
    }

    /// Decodes and crops the poster for every display so a click moments later paints instantly.
    func prewarm(_ wallpaper: Wallpaper) {
        for d in desktop.displays {
            let focus = state.settings(wallpaper.id).focus(for: d.id) ?? wallpaper.manifest.focus
            PosterCache.shared.image(wallpaper, size: d.pixelSize, focus: focus) { _ in }
        }
    }

    // MARK: Per-wallpaper settings

    func settings(_ id: String) -> WallpaperSettings { state.settings(id) }

    func isAudible(_ id: String) -> Bool { !state.settings(id).muted && !prefs.globalMute }

    /// Turning a wallpaper's sound on also lifts the mute-all switch, or the button would do nothing.
    func toggleSound(_ id: String) {
        if isAudible(id) {
            update(id) { $0.muted = true }
        } else {
            prefs.globalMute = false
            update(id) { $0.muted = false }
        }
    }

    @ObservationIgnored private var soundCache: [String: Bool] = [:]

    /// Whether anything in the package can make sound: a scene soundtrack or a video with an audio track.
    func hasSound(_ wallpaper: Wallpaper) async -> Bool {
        let key = "\(wallpaper.id)@\(wallpaper.stamp.timeIntervalSince1970)"
        if let known = soundCache[key] { return known }
        var found = wallpaper.manifest.raw["audio"]?["src"]?.string != nil
        if !found, let files = FileManager.default.enumerator(at: wallpaper.url, includingPropertiesForKeys: nil) {
            let videos = files.compactMap { $0 as? URL }.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
            for url in videos where !found {
                found = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty == false) ?? false
            }
        }
        soundCache[key] = found
        return found
    }

    func update(_ id: String, _ change: (inout WallpaperSettings) -> Void) {
        let old = state.settings(id)
        var s = old
        change(&s)
        state.wallpapers[id] = s
        scheduleSave()
        desktop.refreshSettings(wallpaperID: id)
        if s.cycles != old.cycles { rescheduleCycles() }
    }

    func values(for wallpaper: Wallpaper) -> [String: JSONValue] {
        SceneResolver.effectiveValues(wallpaper.manifest, stored: state.settings(wallpaper.id).values)
    }

    func setValue(_ value: JSONValue, control: String, of wallpaper: Wallpaper) {
        var s = state.settings(wallpaper.id)
        s.values[control] = value
        setValues(s.values, of: wallpaper)
    }

    /// Automatic rotation keeps the poster and desktop picture on the user's own pick: re-rendering them
    /// every time a clip ends costs a third decoder and a full-size encode.
    private func rotate(_ value: JSONValue, control: String, of wallpaper: Wallpaper) {
        var s = state.settings(wallpaper.id)
        s.values[control] = value
        state.wallpapers[wallpaper.id] = s
        scheduleSave()
        SessionStore.shared.update(wallpaperID: wallpaper.id, values: s.values)
    }

    func resetValues(_ wallpaper: Wallpaper) {
        let before = state.settings(wallpaper.id).values
        setValues([:], of: wallpaper)
        registerUndo("Reset Controls") { model in
            guard let wp = model.library.wallpaper(id: wallpaper.id) else { return }
            model.setValues(before, of: wp)
        }
    }

    func applyPreset(_ preset: Preset, to wallpaper: Wallpaper) {
        setValues(preset.values, of: wallpaper)
    }

    private func setValues(_ values: [String: JSONValue], of wallpaper: Wallpaper) {
        var s = state.settings(wallpaper.id)
        s.values = values
        state.wallpapers[wallpaper.id] = s
        scheduleSave()
        SessionStore.shared.update(wallpaperID: wallpaper.id, values: values)
        desktop.updatePointerTracking()
        schedulePersonalPoster(wallpaper)
    }

    @ObservationIgnored private var posterWork: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var posterGeneration: [String: Int] = [:]

    /// Re-renders the first frame with the user's values once they stop changing them. Each render goes to a
    /// temporary file and only the newest may replace the poster, so a slow older render can't win.
    private func schedulePersonalPoster(_ wallpaper: Wallpaper) {
        posterWork[wallpaper.id]?.cancel()
        let generation = posterGeneration[wallpaper.id, default: 0] + 1
        posterGeneration[wallpaper.id] = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let wp = self.library.wallpaper(id: wallpaper.id) else { return }
                let values = self.state.settings(wp.id).values
                Task {
                    let fm = FileManager.default
                    if values.isEmpty {
                        try? fm.removeItem(at: wp.personalPosterURL)
                    } else {
                        let temp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).heic")
                        guard (try? await PosterMaker.make(for: wp, values: values, to: temp)) != nil else { return }
                        guard self.posterGeneration[wp.id] == generation else {
                            try? fm.removeItem(at: temp)
                            return
                        }
                        _ = try? fm.replaceItemAt(wp.personalPosterURL, withItemAt: temp)
                    }
                    PosterCache.shared.invalidate(wp.id)
                    if self.prefs.syncDesktopPicture {
                        DesktopPicture.sync(wp, screens: NSScreen.screens.filter { self.wallpaper(forDisplay: $0.stableKey)?.id == wp.id })
                    }
                }
            }
        }
        posterWork[wallpaper.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func savePreset(named name: String, for wallpaper: Wallpaper) {
        update(wallpaper.id) { $0.presets.append(Preset(name: name, values: values(for: wallpaper))) }
    }

    func deletePreset(_ preset: Preset, of wallpaper: Wallpaper) {
        let before = state.settings(wallpaper.id).presets
        update(wallpaper.id) { $0.presets.removeAll { $0.id == preset.id } }
        registerUndo("Delete Preset “\(preset.name)”") { model in
            model.update(wallpaper.id) { $0.presets = before }
        }
    }

    func resetDisplaySettings(_ wallpaper: Wallpaper) {
        let before = state.settings(wallpaper.id)
        registerUndo("Reset Adjustments") { model in
            model.update(wallpaper.id) { $0 = before }
        }
        update(wallpaper.id) { s in
            let keep = s
            s = WallpaperSettings()
            s.values = keep.values
            s.cycles = keep.cycles
            s.presets = keep.presets
            s.volume = keep.volume
            s.muted = keep.muted
        }
    }

    func renderSettings(_ wallpaper: Wallpaper, display: String) -> RenderSettings {
        let s = state.settings(wallpaper.id)
        let quality = monitor.onBattery ? prefs.batteryQuality : prefs.quality
        var r = RenderSettings()
        r.focus = s.focus(for: display)
        r.showAll = s.showAll
        r.speed = s.speed
        r.fpsCap = effectiveFPSCap(s)
        r.grade = s.grade
        r.parallaxStrength = s.parallax
        r.pointerParallax = prefs.pointerParallax
        r.renderScale = quality.renderScale
        r.volume = s.volume * prefs.masterVolume
        r.muted = s.muted || prefs.globalMute || desktop.focusMuted
        r.maxFPS = Int(desktop.screen(for: display)?.maximumFramesPerSecond ?? 120)
        return r
    }

    /// The Settings limit is a ceiling; a wallpaper's own choice can only lower it.
    func effectiveFPSCap(_ s: WallpaperSettings) -> Int {
        [s.fpsCap, prefs.frameRateCap].filter { $0 > 0 }.min() ?? 0
    }

    // MARK: Auto-cycling choice controls

    private func rescheduleCycles() {
        cycleTimers.values.forEach { $0.invalidate() }
        cycleTimers.removeAll()
        for id in activeWallpaperIDs {
            guard let wp = library.wallpaper(id: id) else { continue }
            for (controlID, cycle) in state.settings(id).cycles(for: wp.manifest) where cycle.minutes > 0 && !cycle.afterClip {
                guard let control = wp.manifest.allControls.first(where: { $0.id == controlID }), control.options.count > 1 else { continue }
                let key = "\(id)|\(controlID)"
                cycleTimers[key] = Timer.scheduledTimer(withTimeInterval: TimeInterval(cycle.minutes * 60), repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.advance(control, of: wp, cycle: cycle) }
                }
            }
        }
    }

    private func clipEnded(wallpaperID id: String) {
        guard activeWallpaperIDs.contains(id), let wp = library.wallpaper(id: id) else { return }
        for (controlID, cycle) in state.settings(id).cycles(for: wp.manifest) where cycle.afterClip {
            guard let control = wp.manifest.allControls.first(where: { $0.id == controlID }) else { continue }
            advance(control, of: wp, cycle: cycle)
        }
    }

    func advance(_ control: Control, of wallpaper: Wallpaper, cycle: CycleSetting?) {
        guard desktop.pauseReason == nil,
              let next = (cycle ?? CycleSetting()).next(after: values(for: wallpaper)[control.id], in: control)
        else { return }
        rotate(next, control: control.id, of: wallpaper)
    }

    // MARK: Favorites, recents, shuffle

    func isFavorite(_ id: String) -> Bool { state.favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if state.favorites.contains(id) { state.favorites.remove(id) } else { state.favorites.insert(id) }
        save()
    }

    var recentWallpapers: [Wallpaper] { state.recents.compactMap { library.wallpaper(id: $0) } }

    /// With different wallpapers per display, every display gets its own pick.
    func shuffle() {
        let usable = library.wallpapers.filter(canApply)
        let favorites = usable.filter { state.favorites.contains($0.id) }
        let pool = prefs.shuffleSource == .favorites && !favorites.isEmpty ? favorites : usable
        var taken = activeWallpaperIDs
        guard prefs.perDisplay, desktop.displays.count > 1 else {
            if let next = pool.filter({ !taken.contains($0.id) }).randomElement() { apply(next, to: .everywhere) }
            return
        }
        let before = snapshotAssignments()
        for d in desktop.displays {
            guard let next = pool.filter({ !taken.contains($0.id) }).randomElement() ?? pool.filter({ $0.id != d.wallpaperID }).randomElement() else { continue }
            state.assignments[d.id] = next.id
            taken.insert(next.id)
        }
        commitAssignments(undo: before, name: "Shuffle")
    }

    /// Every screen's macOS desktop picture follows the wallpaper on it, including screens that just connected.
    func syncDesktopPictures() {
        guard prefs.syncDesktopPicture else { return }
        for screen in NSScreen.screens {
            if let wp = wallpaper(forDisplay: screen.stableKey) {
                DesktopPicture.sync(wp, screens: [screen])
            } else {
                DesktopPicture.restoreOriginal(screens: [screen])
            }
        }
    }

    private func observeDesktopPictureSync() {
        withObservationTracking {
            _ = prefs.syncDesktopPicture
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.prefs.syncDesktopPicture {
                        self.syncDesktopPictures()
                    } else {
                        DesktopPicture.restoreOriginal(screens: NSScreen.screens)
                    }
                    self.observeDesktopPictureSync()
                }
            }
        }
    }

    private func observeShuffle() {
        withObservationTracking {
            _ = prefs.shuffleMinutes
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.rescheduleShuffle()
                    self?.observeShuffle()
                }
            }
        }
    }

    private func rescheduleShuffle() {
        shuffleTimer?.invalidate()
        guard prefs.shuffleMinutes > 0 else { return }
        shuffleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(prefs.shuffleMinutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.desktop.pauseReason == nil else { return }
                self.shuffle()
            }
        }
    }

    // MARK: Library

    struct ImportJob: Identifiable {
        let id = UUID()
        let title: String
    }

    /// Packages being copied in, shown as placeholders in the library.
    private(set) var importing: [ImportJob] = []

    func importItems(_ urls: [URL]) {
        Task { await importAll(urls) }
    }

    /// Packages are copied in the background, asking before one replaces a copy already in the library;
    /// media files start a new wallpaper in Create. Every failure is reported together at the end.
    @discardableResult
    func importAll(_ urls: [URL]) async -> [Wallpaper] {
        var media: [URL] = []
        var imported: [Wallpaper] = []
        var failures: [String] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(Manifest.fileName).path) else {
                media.append(url)
                continue
            }
            do {
                let incoming = try Wallpaper.load(url)
                if let existing = library.existing(for: incoming, at: url), !existing.linked, !confirmReplace(existing) { continue }
                let job = ImportJob(title: incoming.title)
                importing.append(job)
                defer { importing.removeAll { $0.id == job.id } }
                let wp = try await library.importPackage(at: url)
                noteAdded(wp.id)
                imported.append(wp)
            } catch {
                failures.append("\(url.lastPathComponent): \(Self.describe(error))")
            }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "A package couldn’t be added" : "\(failures.count) packages couldn’t be added"
            alert.informativeText = failures.joined(separator: "\n\n")
            alert.runModal()
        }
        if !media.isEmpty {
            creator.begin(with: media)
            requestedPage = .create
        }
        return imported
    }

    private func confirmReplace(_ existing: Wallpaper) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace “\(existing.title)”?"
        alert.informativeText = "Your library already has this wallpaper. Your settings for it are kept, and the old copy goes to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as LocalizedError where e.errorDescription != nil: e.errorDescription ?? ""
        case let e as ManifestError: e.description
        case let e as ShaderCompileError: e.description
        default: error.localizedDescription
        }
    }

    /// Opening a package from Finder adds it and puts it on the desktop straight away.
    func open(_ urls: [URL]) {
        // SwiftUI and the app delegate can both deliver the same Finder open.
        let now = Date()
        let fresh = urls.filter { now.timeIntervalSince(recentlyOpened[$0] ?? .distantPast) > 3 }
        fresh.forEach { recentlyOpened[$0] = now }
        guard !fresh.isEmpty else { return }
        Task {
            if let last = await importAll(fresh).last { apply(last) }
        }
    }

    @ObservationIgnored private var recentlyOpened: [URL: Date] = [:]

    func link(_ url: URL) {
        do {
            let wp = try library.link(url)
            noteAdded(wp.id)
            state.linked = library.linkedPaths
            save()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The Create page's finished package moves into the library; a failure goes back to Create with the draft intact.
    private func created(_ url: URL) async throws {
        let wp = try await library.importPackage(at: url, move: true)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        noteAdded(wp.id)
        apply(wp)
    }

    private func noteAdded(_ id: String) {
        if state.added[id] == nil {
            state.added[id] = Date()
            save()
        }
    }

    func delete(_ wallpaper: Wallpaper) {
        let before = state
        let removal: LibraryStore.Removal
        do {
            removal = try library.delete(wallpaper)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        state.assignments = state.assignments.filter { $0.value != wallpaper.id }
        state.favorites.remove(wallpaper.id)
        state.recents.removeAll { $0 == wallpaper.id }
        state.wallpapers.removeValue(forKey: wallpaper.id)
        state.added.removeValue(forKey: wallpaper.id)
        state.linked = library.linkedPaths
        save()
        desktop.reloadAssignments()
        rescheduleCycles()
        syncDesktopPictures()

        let token = UndoToken()
        let restore: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.undoManager?.removeAllActions(withTarget: token)
            self.restore(wallpaper.id, from: removal, state: before)
        }
        let name = wallpaper.linked ? "Remove “\(wallpaper.title)”" : "Move “\(wallpaper.title)” to Trash"
        undoManager?.registerUndo(withTarget: token) { _ in MainActor.assumeIsolated { restore() } }
        undoManager?.setActionName(name)
        showToast(wallpaper.linked ? "Removed “\(wallpaper.title)” from your library" : "Moved “\(wallpaper.title)” to the Trash",
                  action: ToastAction(title: "Undo", run: restore))
    }

    func removeBroken(_ broken: BrokenPackage) {
        do {
            let removal = try library.remove(broken.url)
            state.linked = library.linkedPaths
            save()
            let name = broken.url.deletingPathExtension().lastPathComponent
            var message = "Moved “\(name)” to the Trash"
            if case .unlinked = removal { message = "Removed “\(name)” from your library" }
            showToast(message, action: ToastAction(title: "Undo") { [weak self] in
                          guard let self else { return }
                          try? self.library.restore(removal)
                          self.state.linked = self.library.linkedPaths
                          self.save()
                      })
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func restore(_ id: String, from removal: LibraryStore.Removal, state before: AppState) {
        do {
            try library.restore(removal)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        for (display, assigned) in before.assignments where assigned == id { state.assignments[display] = id }
        if before.favorites.contains(id) { state.favorites.insert(id) }
        if let i = before.recents.firstIndex(of: id) { state.recents.insert(id, at: min(i, state.recents.count)) }
        state.wallpapers[id] = before.wallpapers[id]
        state.added[id] = before.added[id]
        state.linked = library.linkedPaths
        save()
        desktop.reloadAssignments()
        rescheduleCycles()
        syncDesktopPictures()
        toast = nil
    }

    // MARK: Undo and feedback

    @ObservationIgnored weak var undoManager: UndoManager?

    private final class UndoToken {}

    private func registerUndo(_ name: String, _ body: @escaping @MainActor (AppModel) -> Void) {
        undoManager?.registerUndo(withTarget: self) { model in MainActor.assumeIsolated { body(model) } }
        undoManager?.setActionName(name)
    }

    struct ToastAction {
        var title: String
        var run: @MainActor () -> Void
    }

    struct Toast: Identifiable {
        let id = UUID()
        var message: String
        var action: ToastAction?
    }

    /// A short note at the bottom of the window, with an optional action such as Undo.
    private(set) var toast: Toast?

    func showToast(_ message: String, action: ToastAction? = nil) {
        let next = Toast(message: message, action: action)
        toast = next
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 4 : 8)) { [weak self] in
            MainActor.assumeIsolated {
                if self?.toast?.id == next.id { self?.toast = nil }
            }
        }
    }

    func dismissToast() { toast = nil }

    /// A page the window should switch to, e.g. Create after media was dropped anywhere.
    var requestedPage: SidebarItem?

    /// Reloading first lets the screens move to the new session, so the purge also frees the old one at once.
    private func libraryChanged(_ changed: Set<String>, _ removed: Set<String>) {
        desktop.reloadAssignments()
        for id in changed.union(removed) {
            PosterCache.shared.invalidate(id)
            SessionStore.shared.purge(wallpaperID: id)
        }
        for id in removed {
            try? FileManager.default.removeItem(at: Paths.personalPosters.appendingPathComponent("\(id).heic"))
            try? FileManager.default.removeItem(at: Paths.generatedPosters.appendingPathComponent("\(id).heic"))
        }
        rescheduleCycles()
    }

    /// The bundled samples are copied in on first launch so the library never starts empty.
    private func installSamplesIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: "samplesInstalled"),
              let samples = Bundle.main.url(forResource: "Samples", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
        else { return }
        UserDefaults.standard.set(true, forKey: "samplesInstalled")
        var first: Wallpaper?
        for item in items where item.pathExtension == Manifest.packageExtension {
            if let wp = try? await library.importPackage(at: item) {
                noteAdded(wp.id)
                first = first ?? wp
            }
        }
        if state.assignments.isEmpty, let first { apply(first) }
    }

    // MARK: Screen saver

    func useAsScreenSaver(_ wallpaper: Wallpaper) {
        prefs.saverWallpaperID = wallpaper.id
        prefs.saverSource = .wallpaper
        screenSaver.refresh()
        let saver = screenSaver
        switch saver.status {
        case .installed where saver.isSelected:
            showToast("“\(wallpaper.title)” will play as your screen saver.")
        case .installed:
            showToast("“\(wallpaper.title)” will play once MacPaper is your screen saver.",
                      action: ToastAction(title: "Open Settings") { saver.openSystemSettings() })
        case .unavailable:
            showToast("The screen saver is only available when MacPaper runs from its app bundle.")
        case .notInstalled, .outdated:
            showToast("Install the MacPaper screen saver to play “\(wallpaper.title)”.",
                      action: ToastAction(title: "Install") { saver.install() })
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.shared.write("Launch at login failed: \(error)")
            }
        }
    }

    // MARK: URL commands

    func handle(_ url: URL) -> Bool {
        guard url.scheme == "macpaper" else { return false }
        // Like file opens, a URL can arrive through both SwiftUI and the app delegate; `toggle` would undo itself.
        let now = Date()
        if now.timeIntervalSince(recentlyOpened[url] ?? .distantPast) < 1 { return true }
        recentlyOpened[url] = now
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host {
        case "apply":
            if let id = q("id"), let wp = library.wallpaper(id: id) ?? library.wallpapers.first(where: { $0.title.caseInsensitiveCompare(id) == .orderedSame }) {
                apply(wp)
            }
        case "set":
            guard let wp = q("id").flatMap(library.wallpaper(id:)) ?? currentWallpaper,
                  let controlID = q("control"), let raw = q("value"),
                  let control = wp.manifest.allControls.first(where: { $0.id == controlID }) else { break }
            setValue(control.value(fromUserInput: raw), control: controlID, of: wp)
        case "link":
            guard let path = q("path") else { break }
            link(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
            if q("apply") != "false", let wp = library.wallpapers.first(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path }) {
                apply(wp)
            }
        case "next": shuffle()
        case "pause": desktop.userPaused = true
        case "resume": desktop.userPaused = false
        case "toggle": desktop.userPaused.toggle()
        default: return false
        }
        return true
    }

    // MARK: Persistence

    func save() {
        saveWork?.cancel()
        state.save()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.state.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

enum DesktopPicture {
    private static let originalsKey = "originalDesktopPictures"

    /// The poster becomes the macOS desktop picture, so Mission Control, login and the menu bar tint match.
    @MainActor
    static func sync(_ wallpaper: Wallpaper, screens: [NSScreen]) {
        guard let poster = wallpaper.effectivePosterURL else { return }
        let version = (try? poster.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? wallpaper.stamp
        let dest = Paths.desktopPictures.appendingPathComponent("\(wallpaper.id)-\(Int(version.timeIntervalSince1970)).\(poster.pathExtension)")
        if !FileManager.default.fileExists(atPath: dest.path) {
            if let old = try? FileManager.default.contentsOfDirectory(at: Paths.desktopPictures, includingPropertiesForKeys: nil) {
                for f in old where f.lastPathComponent.hasPrefix(wallpaper.id) { try? FileManager.default.removeItem(at: f) }
            }
            try? FileManager.default.copyItem(at: poster, to: dest)
        }
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        for screen in screens {
            if originals[screen.stableKey] == nil, let current = NSWorkspace.shared.desktopImageURL(for: screen),
               !current.path.hasPrefix(Paths.desktopPictures.path) {
                originals[screen.stableKey] = current.path
            }
            try? NSWorkspace.shared.setDesktopImageURL(dest, for: screen, options: [:])
        }
        UserDefaults.standard.set(originals, forKey: originalsKey)
    }

    static func restoreOriginal(screens: [NSScreen]) {
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        for screen in screens {
            guard let path = originals[screen.stableKey] else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
            originals.removeValue(forKey: screen.stableKey)
        }
        UserDefaults.standard.set(originals, forKey: originalsKey)
    }
}
