import AVFoundation
import Metal
import MetalKit

/// Everything a wallpaper needs at runtime, shared by every display (and the inspector preview) showing it:
/// decoded textures, compiled shaders, video decoders, the clock and audio.
@MainActor
final class SceneSession {
    /// Posted when a playing clip reaches its end; `userInfo["layer"]` names the layer.
    static let clipEnded = Notification.Name("MacPaperClipEnded")

    let wallpaper: Wallpaper
    private(set) var scene: ResolvedScene
    private(set) var values: [String: JSONValue]

    private var textures: [String: MTLTexture] = [:]
    private var textureLoading: Set<String> = []
    private(set) var textureErrors: [String: String] = [:]
    private var programs: [String: ShaderProgram] = [:]
    private var programLoading: Set<String> = []
    private(set) var shaderErrors: [String: ShaderCompileError] = [:]
    private var videos: [String: VideoSource] = [:]
    /// Clips being replaced stay on screen until their successor has a frame, so switching never flashes black;
    /// with `crossfade` the successor then fades in over them.
    private var outgoing: [String: Outgoing] = [:]

    private struct Outgoing {
        let source: VideoSource
        let fade: Double
        var fadeStart: CFTimeInterval?
    }
    private var audioPlayer: AVAudioPlayer?
    private var listeners: [ObjectIdentifier: () -> Void] = [:]
    private var playingConsumers: Set<ObjectIdentifier> = []
    private var baseTime = 0.0
    private var runningSince: CFTimeInterval?
    private(set) var speed = 1.0
    /// Every surface showing this session asks for its own sound; one muted preview must not silence the desktop.
    private var audioRequests: [ObjectIdentifier: Double] = [:]
    private var volume: Double { audioRequests.values.max() ?? 0 }
    private var muted: Bool { audioRequests.isEmpty }
    private var gpuFaults: [CFTimeInterval] = []
    private(set) var shadersDisabled = false
    private(set) var caption: Caption?
    private var captionSerial = 0
    private var pendingCaptions: [String: (kind: Caption.Kind, clip: String)] = [:]
    private var arrivals: [String: Int] = [:]
    private var lastIdle: [String: Int] = [:]
    private var idleTimer: Timer?
    var spectrum = AudioSpectrum.silent

    init(wallpaper: Wallpaper, values: [String: JSONValue]) {
        self.wallpaper = wallpaper
        self.values = values
        scene = SceneResolver.resolve(wallpaper.manifest, values: values)
        prepare()
        if let audio = scene.audio, let url = wallpaper.file(audio.src) {
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.enableRate = true
            audioPlayer?.prepareToPlay()
        }
        applyAudio()
    }

    // MARK: Values

    func apply(values: [String: JSONValue]) {
        guard values != self.values else { return }
        self.values = values
        scene = SceneResolver.resolve(wallpaper.manifest, values: values)
        prepare()
        notify()
    }

    // MARK: Resources

    private func prepare() {
        var wantedVideos: Set<String> = []
        for layer in scene.layers {
            switch layer.content {
            case .image(let i):
                requestTexture(i.src)
                if let d = i.depth { requestTexture(d) }
            case .shader(let s):
                for t in s.textures { requestTexture(t.path) }
                requestProgram(s, layerID: layer.id)
            case .particles(let p):
                if let m = p.mask { requestTexture(m) }
                if let t = p.texture, p.shape == .texture { requestTexture(t) }
            case .video(let v):
                guard layer.visible, let url = wallpaper.file(v.src) else { continue }
                wantedVideos.insert(layer.id)
                if let existing = videos[layer.id], existing.url == url, existing.loops == (v.crossfade <= 0) {
                    existing.update(spec: v)
                } else {
                    let changed = videos[layer.id].map { $0.url != url } ?? false
                    replaceVideo(layer.id, url: url, spec: v, intro: changed && v.intro)
                }
            }
        }
        for (id, source) in videos where !wantedVideos.contains(id) {
            source.tearDown()
            videos[id] = nil
            outgoing[id]?.source.tearDown()
            outgoing[id] = nil
        }
        applyAudio()
    }

    private func replaceVideo(_ id: String, url: URL, spec: VideoSpec, intro: Bool) {
        if let old = videos[id] {
            outgoing[id]?.source.tearDown()
            outgoing[id] = nil
            if old.latest != nil || old.hasLoaded {
                old.onEnded = nil
                old.setPlaying(false)
                old.setAudio(volume: 0, muted: true)
                outgoing[id] = Outgoing(source: old, fade: spec.crossfade)
            } else {
                old.tearDown()
            }
        }
        if id == scene.captions?.video {
            pendingCaptions[id] = (spec.freeze != nil && !intro ? .restored : .enter, spec.src)
        }
        let source = VideoSource(url: url, spec: spec, intro: intro)
        source.setSpeed(speed)
        source.setPlaying(runningSince != nil)
        source.setAudio(volume: volume, muted: muted)
        source.onEnded = { [weak self, weak source] in
            guard let self, let source else { return }
            self.clipEnded(id, source)
        }
        source.onSettled = { [weak self] in
            guard let self else { return }
            if id == self.scene.captions?.video { self.say(.held, clip: spec.src) }
            self.notify()
        }
        videos[id] = source
        pollVideoReady(source)
    }

    /// Lets the app advance a cycling control first; a clip that is still current afterwards plays again.
    private func clipEnded(_ id: String, _ source: VideoSource) {
        guard videos[id] === source else { return }
        NotificationCenter.default.post(name: Self.clipEnded, object: self, userInfo: ["layer": id])
        guard !source.loops else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.videos[id] === source,
                      let spec = self.scene.layers.first(where: { $0.id == id })?.video, spec.freeze == nil else { return }
                self.replaceVideo(id, url: source.url, spec: spec, intro: false)
            }
        }
    }

    private func pollVideoReady(_ source: VideoSource, attempt: Int = 0) {
        guard videos.values.contains(where: { $0 === source }) else { return }
        if attempt >= 200 || source.isReady || source.frame(hostTime: CACurrentMediaTime()) != nil {
            if let id = videos.first(where: { $0.value === source })?.key, var out = outgoing[id] {
                let old = out.source
                let linger = out.fade + (out.fade > 0 ? 1.0 : 0.4)
                if out.fade > 0, source.latest != nil {
                    out.fadeStart = CACurrentMediaTime()
                    outgoing[id] = out
                    DispatchQueue.main.asyncAfter(deadline: .now() + out.fade) { [weak self] in
                        MainActor.assumeIsolated { self?.notify() }
                    }
                } else {
                    outgoing[id] = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
                    MainActor.assumeIsolated {
                        if let self, self.outgoing[id]?.source === old { self.outgoing[id] = nil }
                        old.tearDown()
                    }
                }
            }
            if let id = videos.first(where: { $0.value === source })?.key, let line = pendingCaptions.removeValue(forKey: id) {
                say(line.kind, clip: line.clip)
            }
            notify()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated { self?.pollVideoReady(source, attempt: attempt + 1) }
        }
    }

    private func requestTexture(_ path: String) {
        guard textures[path] == nil, !textureLoading.contains(path), textureErrors[path] == nil else { return }
        guard let url = wallpaper.file(path), FileManager.default.fileExists(atPath: url.path) else {
            textureErrors[path] = "\(path) not found"
            return
        }
        textureLoading.insert(path)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: true,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ]
        GPU.shared.loader.newTexture(URL: url, options: options) { [weak self] texture, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.textureLoading.remove(path)
                    if let texture {
                        texture.label = path
                        self.textures[path] = texture
                    } else {
                        self.textureErrors[path] = error?.localizedDescription ?? "unreadable image"
                    }
                    self.notify()
                }
            }
        }
    }

    private func requestProgram(_ spec: ShaderSpec, layerID: String) {
        guard let url = wallpaper.file(spec.src), let source = try? String(contentsOf: url, encoding: .utf8) else {
            shaderErrors[layerID] = ShaderCompileError(diagnostics: [ShaderDiagnostic(file: spec.src, line: 0, column: 0, severity: "error", message: "file not found")])
            return
        }
        let key = ShaderProgram.cacheKey(spec, source: source)
        programKeys[layerID] = key
        guard programs[key] == nil, !programLoading.contains(key) else { return }
        programLoading.insert(key)
        let device = GPU.shared.device
        Task { [weak self] in
            let result: Result<ShaderProgram, ShaderCompileError>
            do {
                result = .success(try await ShaderProgram.shared(spec: spec, source: source, fileName: spec.src, device: device))
            } catch let e as ShaderCompileError {
                result = .failure(e)
            } catch {
                result = .failure(ShaderCompileError(diagnostics: [ShaderDiagnostic(file: spec.src, line: 0, column: 0, severity: "error", message: error.localizedDescription)]))
            }
            guard let self else { return }
            self.programLoading.remove(key)
            switch result {
            case .success(let p):
                self.programs[key] = p
                self.shaderErrors[layerID] = nil
            case .failure(let e):
                self.shaderErrors[layerID] = e
                Log.shared.write("Shader \(spec.src) failed:\n\(e.description)")
            }
            self.notify()
        }
    }

    private var programKeys: [String: String] = [:]

    func texture(_ path: String?) -> MTLTexture? {
        path.flatMap { textures[$0] }
    }

    func program(for layerID: String) -> ShaderProgram? {
        guard !shadersDisabled, let key = programKeys[layerID] else { return nil }
        return programs[key]
    }

    /// What a video layer shows at `hostTime`, bottom first: the outgoing clip while its successor loads or
    /// fades in, then the current clip with its fade-in opacity.
    func videoFrames(for layerID: String, hostTime: CFTimeInterval) -> [(frame: VideoFrame, alpha: Float)] {
        let current = videos[layerID]?.frame(hostTime: hostTime)
        guard let out = outgoing[layerID], let old = out.source.frame(hostTime: hostTime) else {
            return current.map { [($0, Float(1))] } ?? []
        }
        guard let current else { return [(old, Float(1))] }
        guard let start = out.fadeStart else { return [(out.fade > 0 ? old : current, Float(1))] }
        let t = min(max((hostTime - start) / max(out.fade, 0.001), 0), 1)
        if t >= 1 { return [(current, Float(1))] }
        return [(old, Float(1)), (current, Float(t * t * (3 - 2 * t)))]
    }

    /// Pulls any frame that is due and returns a value that changes whenever a clip has a new one, so a surface
    /// whose picture is only video can skip redrawing the same frame.
    func videoFrameToken(hostTime: CFTimeInterval) -> Int {
        var token = 0
        for (id, v) in videos {
            _ = v.frame(hostTime: hostTime)
            token = token &* 31 &+ v.serial &+ id.hashValue
        }
        return token
    }

    var isCrossfading: Bool {
        outgoing.values.contains { o in
            o.fadeStart.map { CACurrentMediaTime() - $0 < o.fade + 0.05 } ?? (o.fade > 0)
        }
    }

    func currentVideoSource(for layerID: String) -> VideoSource? {
        videos[layerID]
    }

    func crossfade(for layerID: String) -> Double {
        scene.layers.first { $0.id == layerID }?.video?.crossfade ?? 0
    }

    /// Motion beyond what the resolved scene declares: a clip playing its intro, or a crossfade in progress.
    var hasTransientMotion: Bool {
        videos.values.contains(where: \.isMoving) || outgoing.values.contains { o in
            o.fadeStart.map { CACurrentMediaTime() - $0 < o.fade + 0.05 } ?? false
        }
    }

    /// True once every visible layer has what it needs to draw (or has definitively failed).
    var isReady: Bool {
        for layer in scene.layers where layer.visible {
            switch layer.content {
            case .image(let i):
                if !settled(i.src) || !settled(i.depth) { return false }
            case .shader(let s):
                if shaderErrors[layer.id] == nil, program(for: layer.id) == nil, !shadersDisabled { return false }
                if s.textures.contains(where: { !settled($0.path) }) { return false }
            case .particles(let p):
                if !settled(p.mask) { return false }
            case .video:
                if let v = videos[layer.id], !v.isReady { return false }
            }
        }
        return true
    }

    private func settled(_ path: String?) -> Bool {
        guard let path else { return true }
        return textures[path] != nil || textureErrors[path] != nil
    }

    var issues: [String] {
        var out = textureErrors.map { "\($0.key): \($0.value)" }
        out += shaderErrors.values.map(\.description)
        out += videos.values.compactMap { v in v.failed.map { "\(v.url.lastPathComponent): \($0)" } }
        if shadersDisabled { out.append("Shaders were disabled after repeated GPU faults.") }
        return out.sorted()
    }

    /// Three faults within half a minute switch shaders off; a stray one long ago doesn't count.
    func reportGPUFault() {
        let now = CACurrentMediaTime()
        gpuFaults = gpuFaults.filter { now - $0 < 30 } + [now]
        if gpuFaults.count >= 3, !shadersDisabled {
            shadersDisabled = true
            Log.shared.write("\(wallpaper.title): shaders disabled after GPU faults")
            notify()
        }
    }

    // MARK: Clock & playback

    func time(at now: CFTimeInterval) -> Double {
        guard let since = runningSince else { return baseTime }
        return baseTime + (now - since) * speed
    }

    /// Jumps the clock (and every clip) to `seconds`; used for posters and CLI renders.
    func setTime(_ seconds: Double) {
        baseTime = seconds
        if runningSince != nil { runningSince = CACurrentMediaTime() }
        for (id, v) in videos {
            let rate = scene.layers.first { $0.id == id }?.video?.rate ?? 1
            v.seek(to: seconds * rate)
        }
    }

    func setSpeed(_ speed: Double) {
        guard speed != self.speed else { return }
        let now = CACurrentMediaTime()
        baseTime = time(at: now)
        if runningSince != nil { runningSince = now }
        self.speed = speed
        videos.values.forEach { $0.setSpeed(speed) }
        audioPlayer?.rate = Float(speed)
    }

    func setPlaying(_ playing: Bool, consumer: AnyObject) {
        let id = ObjectIdentifier(consumer)
        if playing { playingConsumers.insert(id) } else { playingConsumers.remove(id) }
        let running = !playingConsumers.isEmpty
        guard running != (runningSince != nil) else { return }
        let now = CACurrentMediaTime()
        if running {
            runningSince = now
        } else {
            baseTime = time(at: now)
            runningSince = nil
        }
        videos.values.forEach { $0.setPlaying(running) }
        applyAudio()
    }

    var isRunning: Bool { runningSince != nil }

    /// `audible` is false for a surface that is muted or paused; the session plays sound while any surface is audible.
    func setAudio(volume: Double, audible: Bool, consumer: AnyObject) {
        audioRequests[ObjectIdentifier(consumer)] = audible ? volume : nil
        applyAudio()
    }

    private func applyAudio() {
        for v in videos.values { v.setAudio(volume: volume, muted: muted) }
        guard let audioPlayer else { return }
        audioPlayer.volume = Float(volume * (scene.audio?.volume ?? 1))
        if muted || runningSince == nil || scene.audio == nil {
            audioPlayer.pause()
        } else if !audioPlayer.isPlaying {
            audioPlayer.play()
        }
    }

    // MARK: Listeners

    func observe(_ owner: AnyObject, _ body: @escaping () -> Void) {
        listeners[ObjectIdentifier(owner)] = body
    }

    func unobserve(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
        setPlaying(false, consumer: owner)
    }

    private func notify() {
        listeners.values.forEach { $0() }
    }

    /// AVPlayer only shows video in the most recently created AVPlayerLayer, so one surface owns the direct
    /// video path and every other surface draws the same frames through Metal.
    private var directVideoOwner: ObjectIdentifier?

    func canUseDirectVideo(_ surface: AnyObject) -> Bool {
        directVideoOwner == nil || directVideoOwner == ObjectIdentifier(surface)
    }

    func claimDirectVideo(_ surface: AnyObject) {
        directVideoOwner = ObjectIdentifier(surface)
    }

    func releaseDirectVideo(_ surface: AnyObject) {
        guard directVideoOwner == ObjectIdentifier(surface) else { return }
        directVideoOwner = nil
        notify()
    }

    // MARK: Captions

    private func say(_ kind: Caption.Kind, clip: String) {
        idleTimer?.invalidate()
        idleTimer = nil
        guard let spec = scene.captions, let lines = spec.lines[clip] else { return }
        func pick(_ list: [Localized], _ n: Int) -> Localized? { list.isEmpty ? nil : list[n % list.count] }
        let line: Localized?
        switch kind {
        case .enter:
            let n = arrivals[clip, default: 0]
            arrivals[clip] = n + 1
            line = pick(lines.enter, n)
        case .held:
            line = pick(lines.held, max(arrivals[clip, default: 1] - 1, 0))
        case .restored:
            let n = arrivals[clip, default: 0]
            arrivals[clip] = n + 1
            line = pick(lines.restored, n) ?? pick(lines.held, n)
        case .idle:
            var n = Int.random(in: 0..<max(lines.idle.count, 1))
            if lines.idle.count > 1, n == lastIdle[clip] { n = (n + 1) % lines.idle.count }
            lastIdle[clip] = n
            line = pick(lines.idle, n)
        }
        if let line {
            captionSerial += 1
            caption = Caption(serial: captionSerial, line: line, kind: kind, shownAt: CACurrentMediaTime())
            notify()
        }
        if kind != .enter, spec.idleEvery > 0, !lines.idle.isEmpty {
            idleTimer = Timer.scheduledTimer(withTimeInterval: spec.idleEvery, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.idleTimerFired(clip: clip) }
            }
        }
    }

    /// Idle lines only come while she holds the pose on screen; otherwise the timer just waits for the next turn.
    private func idleTimerFired(clip: String) {
        guard let spec = scene.captions, let layer = scene.layers.first(where: { $0.id == spec.video })?.video,
              layer.src == clip, layer.freeze != nil, videos[spec.video]?.isMoving == false
        else { return }
        if runningSince != nil {
            say(.idle, clip: clip)
        } else {
            idleTimer = Timer.scheduledTimer(withTimeInterval: spec.idleEvery, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.idleTimerFired(clip: clip) }
            }
        }
    }

    func tearDown() {
        idleTimer?.invalidate()
        idleTimer = nil
        videos.values.forEach { $0.tearDown() }
        videos.removeAll()
        outgoing.values.forEach { $0.source.tearDown() }
        outgoing.removeAll()
        audioPlayer?.stop()
        audioPlayer = nil
        listeners.removeAll()
    }
}

struct Caption: Equatable {
    enum Kind { case enter, held, restored, idle }
    let serial: Int
    let line: Localized
    let kind: Kind
    let shownAt: CFTimeInterval

    /// An entrance line stays until the held line replaces it as she settles.
    var duration: Double { kind == .enter ? 12 : 8 }
}

/// Keeps sessions alive while used, and briefly afterwards so re-applying or pre-warming is instant.
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private struct Entry {
        var session: SceneSession
        var refs: Int
        var expiry: DispatchWorkItem?
    }

    private var entries: [String: Entry] = [:]
    var linger: TimeInterval = 30

    private func key(_ w: Wallpaper) -> String { "\(w.id)@\(w.stamp.timeIntervalSince1970)" }

    func acquire(_ wallpaper: Wallpaper, values: [String: JSONValue]) -> SceneSession {
        let k = key(wallpaper)
        if var e = entries[k] {
            e.expiry?.cancel()
            e.expiry = nil
            e.refs += 1
            entries[k] = e
            e.session.apply(values: values)
            return e.session
        }
        let s = SceneSession(wallpaper: wallpaper, values: values)
        entries[k] = Entry(session: s, refs: 1)
        return s
    }

    func release(_ session: SceneSession) {
        let k = key(session.wallpaper)
        guard var e = entries[k], e.session === session else {
            session.tearDown()
            return
        }
        e.refs -= 1
        if e.refs <= 0 {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let current = self.entries[k], current.refs <= 0 else { return }
                    current.session.tearDown()
                    self.entries[k] = nil
                }
            }
            e.expiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
        }
        entries[k] = e
    }

    /// Starts loading a wallpaper so applying it moments later is immediate.
    func prewarm(_ wallpaper: Wallpaper, values: [String: JSONValue]) {
        release(acquire(wallpaper, values: values))
    }

    func update(wallpaperID: String, values: [String: JSONValue]) {
        for e in entries.values where e.session.wallpaper.id == wallpaperID {
            e.session.apply(values: values)
        }
    }

    func sessions(for wallpaperID: String) -> [SceneSession] {
        entries.values.filter { $0.session.wallpaper.id == wallpaperID && $0.refs > 0 }.map(\.session)
    }

    var all: [SceneSession] { entries.values.filter { $0.refs > 0 }.map(\.session) }

    func purge(wallpaperID: String) {
        for (k, e) in entries where e.session.wallpaper.id == wallpaperID && e.refs <= 0 {
            e.expiry?.cancel()
            e.session.tearDown()
            entries[k] = nil
        }
    }
}
