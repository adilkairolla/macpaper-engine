import Foundation

enum Blend: String, Hashable, Sendable, CaseIterable { case normal, add, screen, multiply }
enum Fit: String, Hashable, Sendable { case fill, fit, stretch }
enum Daypart: String, Hashable, Sendable { case always, day, night }

enum ParamType: String, Hashable, Sendable, CaseIterable {
    case float, float2, float3, float4, color, int, bool

    var mslType: String {
        switch self {
        case .float: "float"
        case .float2: "float2"
        case .float3: "float3"
        case .float4, .color: "float4"
        case .int, .bool: "int"
        }
    }
}

struct ShaderParam: Hashable, Sendable {
    var name: String
    var type: ParamType
    var value: JSONValue
}

struct VideoSpec: Hashable, Sendable {
    var src: String
    var rate: Double
    var freeze: Double?
    var volume: Double
    var intro: Bool
    var crossfade: Double
}

struct ImageSpec: Hashable, Sendable {
    var src: String
    var depth: String?
    var depthStrength: Double
}

struct ShaderSpec: Hashable, Sendable {
    var src: String
    var function: String
    var params: [ShaderParam]
    var textures: [(name: String, path: String)]

    static func == (a: ShaderSpec, b: ShaderSpec) -> Bool {
        a.src == b.src && a.function == b.function && a.params == b.params
            && a.textures.map(\.name) == b.textures.map(\.name) && a.textures.map(\.path) == b.textures.map(\.path)
    }

    func hash(into h: inout Hasher) {
        h.combine(src); h.combine(function); h.combine(params)
        for t in textures { h.combine(t.name); h.combine(t.path) }
    }
}

enum ParticleShape: String, Hashable, Sendable, CaseIterable {
    case dot, glow, streak, ring, petal, texture
    var index: Int32 { Int32(Self.allCases.firstIndex(of: self)!) }
}

struct ParticleSpec: Hashable, Sendable {
    var count: Int
    var area: NormRect
    var mask: String?
    var lifetime: Range2
    var speed: Range2
    var direction: Double
    var spread: Double
    var gravity: SIMD2<Double>
    var wind: SIMD2<Double>
    var turbulence: Double
    var turbulenceScale: Double
    var size: Range2
    var color: RGBA
    var colorEnd: RGBA
    var fade: Range2
    var twinkle: Double
    var shape: ParticleShape
    var texture: String?
    var spin: Range2
    var stretch: Double
    var mouse: Double

    static let maxCount = 20_000
}

struct LayerSpec: Hashable, Sendable {
    enum Content: Hashable, Sendable {
        case video(VideoSpec)
        case image(ImageSpec)
        case shader(ShaderSpec)
        case particles(ParticleSpec)
    }

    var id: String
    var content: Content
    var opacity: Double
    var visible: Bool
    var blend: Blend
    var rect: NormRect
    var fit: Fit
    var parallax: Double
    var daypart: Daypart

    var typeName: String {
        switch content {
        case .video: "video"
        case .image: "image"
        case .shader: "shader"
        case .particles: "particles"
        }
    }

    var video: VideoSpec? { if case .video(let v) = content { v } else { nil } }
}

struct AudioSpec: Hashable, Sendable {
    var src: String
    var volume: Double
}

/// What a character says at each moment of one clip; enter and held lines pair up by index.
struct CaptionLines: Hashable, Sendable {
    var enter: [Localized] = []
    var held: [Localized] = []
    var restored: [Localized] = []
    var idle: [Localized] = []
}

struct CaptionsSpec: Hashable, Sendable {
    var video: String
    var lang: String
    var speaker: String?
    var idleEvery: Double
    var lines: [String: CaptionLines]

    var isOff: Bool { lang == "off" }

    func text(_ line: Localized) -> String {
        lang == "auto" ? line.text : line.values[lang] ?? line.text
    }

    static func decode(_ c: JSONValue?) -> CaptionsSpec? {
        guard let c, let video = c["video"]?.string else { return nil }
        var lines: [String: CaptionLines] = [:]
        for (src, v) in c["lines"]?.object ?? [:] {
            func list(_ key: String) -> [Localized] { (v[key]?.array ?? []).compactMap { Localized($0) } }
            lines[src] = CaptionLines(enter: list("enter"), held: list("held"), restored: list("restored"), idle: list("idle"))
        }
        return CaptionsSpec(
            video: video, lang: c["lang"]?.string ?? "auto", speaker: c["speaker"]?.string,
            idleEvery: max(c["idleEvery"]?.number ?? 0, 0), lines: lines
        )
    }
}

enum ReactionTrigger: String, Hashable, Sendable, CaseIterable {
    case unlock, wake, comeBack = "return", click, time, random, idle, charge, music, meeting
}

/// Short clips a video layer plays once when something happens, then goes back to where its loop was.
struct ReactionsSpec: Hashable, Sendable {
    struct Rule: Hashable, Sendable {
        var trigger: ReactionTrigger
        var clips: [String]
        var cooldown: Double?
        /// `return` and `idle`: how long without input, in seconds.
        var idle: Double
        /// `random`: the average gap between reactions, in seconds.
        var every: Double
        /// `time`: minutes after midnight.
        var at: [Int]
        /// `meeting`: how many minutes before the event starts.
        var before: Double = 2
        /// Only between these times of day.
        var between: TimeWindow?
    }

    /// Minutes after midnight; `from` after `to` runs past midnight.
    struct TimeWindow: Hashable, Sendable {
        var from: Int
        var to: Int

        func contains(_ date: Date) -> Bool {
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            return from <= to ? (from..<to).contains(m) : m >= from || m < to
        }

        static func decode(_ v: JSONValue?) -> TimeWindow? {
            guard let a = v?.array, a.count == 2,
                  let from = a[0].string.flatMap(minutesAfterMidnight), let to = a[1].string.flatMap(minutesAfterMidnight),
                  from != to else { return nil }
            return TimeWindow(from: from, to: to)
        }
    }

    static let defaultCooldown = 30.0
    static let defaultIdle = 300.0

    var video: String
    var crossfade: Double
    var cooldown: Double
    var rules: [Rule]

    func rule(for trigger: ReactionTrigger) -> Rule? { rules.first { $0.trigger == trigger } }

    static func decode(_ r: JSONValue?) -> ReactionsSpec? {
        guard let r, let video = r["video"]?.string, r["enabled"]?.bool != false else { return nil }
        let rules = (r["events"]?.array ?? []).compactMap { e -> Rule? in
            guard let trigger = e["on"]?.string.flatMap(ReactionTrigger.init(rawValue:)) else { return nil }
            let clips = (e["clips"]?.array ?? []).compactMap(\.string) + [e["clip"]?.string].compactMap { $0 }
            guard !clips.isEmpty else { return nil }
            return Rule(
                trigger: trigger, clips: clips, cooldown: e["cooldown"]?.number.map { max($0, 0) },
                idle: max(e["idle"]?.number ?? defaultIdle, 10), every: max(e["every"]?.number ?? 600, 30),
                at: ((e["at"]?.array ?? [e["at"]].compactMap { $0 }).compactMap { $0.string.flatMap(minutesAfterMidnight) }),
                before: min(max(e["before"]?.number ?? 2, 0), 60), between: TimeWindow.decode(e["between"])
            )
        }
        guard !rules.isEmpty else { return nil }
        return ReactionsSpec(
            video: video, crossfade: min(max(r["crossfade"]?.number ?? 0.8, 0.1), 5),
            cooldown: max(r["cooldown"]?.number ?? defaultCooldown, 0), rules: rules
        )
    }

    /// "23:30" → 1410.
    static func minutesAfterMidnight(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let h = parts[0], let m = parts[1], (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// A video layer that alternates between its clip (the show) and a calm resting loop. The show plays a full
/// cycle from `at`, the moment that matches the resting loop's first frame, hands over to the resting loop there,
/// and comes back after `minutes`, the next time the resting loop wraps.
struct RestSpec: Hashable, Sendable {
    var video: String
    var src: String
    var at: Double
    var minutes: Double

    static func decode(_ r: JSONValue?) -> RestSpec? {
        guard let r, let video = r["video"]?.string, let src = r["src"]?.string, let at = r["at"]?.number else { return nil }
        return RestSpec(video: video, src: src, at: max(at, 0), minutes: max(r["minutes"]?.number ?? 10, 0.5))
    }
}

/// Which part of a show-and-rest wallpaper plays; the person's choice, not the package's.
enum RestMode: String, Codable, CaseIterable, Sendable {
    case cycle, rest, show
}

struct ResolvedScene: Hashable, Sendable {
    var canvas: CGSize
    var fps: Int
    var background: RGBA
    var drift: Double
    var audio: AudioSpec?
    var captions: CaptionsSpec?
    var reactions: ReactionsSpec?
    var rest: RestSpec?
    var layers: [LayerSpec]

    /// One full-canvas video and nothing else: AVPlayerLayer can show it with no GPU composition.
    var isPlainVideo: Bool {
        let shown = layers.filter { $0.visible && $0.opacity > 0 }
        guard shown.count == 1, let l = shown.first, l.video != nil else { return false }
        return l.opacity >= 1 && l.rect == .full && l.fit == .fill && l.parallax == 0 && l.daypart == .always && l.blend == .normal
    }

    var isAnimated: Bool {
        layers.contains { l in
            guard l.visible else { return false }
            switch l.content {
            case .video(let v): return v.freeze == nil
            case .particles, .shader: return true
            case .image: return false
            }
        }
    }

    var usesParallax: Bool {
        layers.contains { l in
            guard l.visible else { return false }
            if l.parallax != 0 { return true }
            if case .image(let i) = l.content, i.depth != nil, i.depthStrength != 0 { return true }
            return false
        }
    }

    var usesDaylight: Bool { layers.contains { $0.daypart != .always } }

    /// Only clips move on their own: no shaders or particles that change every frame.
    var animatedOnlyByVideo: Bool {
        !layers.contains { l in
            guard l.visible else { return false }
            switch l.content {
            case .shader, .particles: return true
            default: return false
            }
        }
    }

    var hasPointerParticles: Bool {
        layers.contains { l in
            if case .particles(let p) = l.content { return l.visible && p.mouse != 0 }
            return false
        }
    }

    /// Anything on screen that reacts to the pointer: parallax, particles that flee it, or shaders reading `mouse`.
    var followsPointer: Bool {
        usesParallax || hasPointerParticles || layers.contains { l in
            if case .shader = l.content { return l.visible }
            return false
        }
    }
}

enum SceneResolver {
    /// The value each control starts with when the user has never touched it.
    static func defaultValue(of control: Control, in manifest: Manifest) -> JSONValue {
        if let d = control.defaultValue { return d }
        let current = control.targets.first.flatMap { PropertyPath.read($0, in: manifest) }
        switch control.kind {
        case .choice:
            if let current, control.options.contains(where: { $0.value == current }) { return current }
            return control.options.first?.value ?? .null
        case .toggle:
            return current?.bool.map(JSONValue.bool) ?? .bool(false)
        case .slider:
            return current?.number.map(JSONValue.number) ?? .number(control.min)
        case .color:
            return RGBA(current).map(\.json) ?? RGBA.white.json
        case .point:
            return current?.numbers?.count == 2 ? current! : JSONValue([0.5, 0.5])
        case .section:
            return .null
        }
    }

    static func effectiveValues(_ manifest: Manifest, stored: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for c in manifest.allControls {
            out[c.id] = stored[c.id] ?? defaultValue(of: c, in: manifest)
        }
        return out
    }

    static func resolve(_ manifest: Manifest, values stored: [String: JSONValue]) -> ResolvedScene {
        var layers = manifest.layers
        var scene = manifest.raw
        let values = effectiveValues(manifest, stored: stored)
        // A control the UI hides doesn't apply: several controls can share a target, one per situation.
        for control in manifest.allControls where control.isVisible(values: values) {
            guard let value = values[control.id] else { continue }
            if control.kind == .choice {
                guard let option = control.option(for: value) ?? control.options.first else { continue }
                for t in control.targets { PropertyPath.write(option.value, to: t, layers: &layers, scene: &scene) }
                for (path, v) in option.set { PropertyPath.write(v, to: path, layers: &layers, scene: &scene) }
            } else {
                for t in control.targets { PropertyPath.write(value, to: t, layers: &layers, scene: &scene) }
            }
        }
        let audio: AudioSpec? = scene["audio"].flatMap { a in
            a["src"]?.string.map { AudioSpec(src: $0, volume: a["volume"]?.number ?? 1) }
        }
        return ResolvedScene(
            canvas: manifest.canvas,
            fps: manifest.fps,
            background: RGBA(scene["background"]) ?? .black,
            drift: min(max(scene["drift"]?.number ?? 0.3, 0), 1),
            audio: audio,
            captions: CaptionsSpec.decode(scene["captions"]),
            reactions: ReactionsSpec.decode(scene["reactions"]),
            rest: RestSpec.decode(scene["rest"]),
            layers: layers.compactMap(LayerDecoder.decode)
        )
    }
}

enum PropertyPath {
    /// What a layer property means when the manifest leaves it out.
    static let defaults: [String: JSONValue] = [
        "visible": true, "opacity": 1, "parallax": 0, "blend": "normal", "fit": "fill", "daypart": "always",
        "rect": JSONValue([0, 0, 1, 1]), "rate": 1, "volume": 1, "freeze": nil, "intro": false, "crossfade": 0,
        "depthStrength": 0.03,
    ]

    static func components(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    static func write(_ value: JSONValue, to path: String, layers: inout [[String: JSONValue]], scene: inout [String: JSONValue]) {
        let parts = components(path)
        guard parts.count >= 2 else { return }
        switch parts[0] {
        case "scene":
            scene[parts[1]] = value
        case "audio", "captions", "reactions":
            var section = scene[parts[0]]?.object ?? [:]
            section[parts[1]] = value
            scene[parts[0]] = .object(section)
        default:
            guard let i = layers.firstIndex(where: { $0["id"]?.string == parts[0] }) else { return }
            if parts.count == 3, parts[1] == "params" {
                var params = layers[i]["params"]?.object ?? [:]
                var param = params[parts[2]]?.object ?? [:]
                param["value"] = value
                params[parts[2]] = .object(param)
                layers[i]["params"] = .object(params)
            } else if parts.count == 3, parts[1] == "textures" {
                var textures = layers[i]["textures"]?.object ?? [:]
                textures[parts[2]] = value
                layers[i]["textures"] = .object(textures)
            } else if parts.count == 2 {
                layers[i][parts[1]] = value
            }
        }
    }

    static func read(_ path: String, in manifest: Manifest) -> JSONValue? {
        let parts = components(path)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "scene": return manifest.raw[parts[1]]
        case "audio": return manifest.raw["audio"]?[parts[1]]
        case "captions": return manifest.raw["captions"]?[parts[1]] ?? (parts[1] == "lang" ? "auto" : nil)
        case "reactions": return manifest.raw["reactions"]?[parts[1]] ?? (parts[1] == "enabled" ? true : nil)
        default:
            guard let layer = manifest.layers.first(where: { $0["id"]?.string == parts[0] }) else { return nil }
            if parts.count == 3, parts[1] == "params" { return layer["params"]?[parts[2]]?["value"] }
            if parts.count == 3, parts[1] == "textures" { return layer["textures"]?[parts[2]] }
            if parts.count == 2 {
                if let v = layer[parts[1]] { return v }
                if layer["type"]?.string == "particles", let v = ParticlePresets.merged(layer)[parts[1]] { return v }
                return defaults[parts[1]]
            }
            return nil
        }
    }
}

enum LayerDecoder {
    static func decode(_ raw: [String: JSONValue]) -> LayerSpec? {
        guard let id = raw["id"]?.string, let type = raw["type"]?.string else { return nil }
        let o = type == "particles" ? ParticlePresets.merged(raw) : raw
        let content: LayerSpec.Content
        switch type {
        case "video":
            guard let src = o["src"]?.string else { return nil }
            content = .video(VideoSpec(
                src: src,
                rate: o["rate"]?.number ?? 1,
                freeze: o["freeze"]?.number.map { min(max($0, 0), 1) },
                volume: min(max(o["volume"]?.number ?? 1, 0), 1),
                intro: o["intro"]?.bool ?? false,
                crossfade: min(max(o["crossfade"]?.number ?? 0, 0), 5)
            ))
        case "image":
            guard let src = o["src"]?.string else { return nil }
            content = .image(ImageSpec(src: src, depth: o["depth"]?.string, depthStrength: o["depthStrength"]?.number ?? 0.03))
        case "shader":
            guard let src = o["src"]?.string else { return nil }
            content = .shader(ShaderSpec(
                src: src,
                function: o["function"]?.string ?? "effect",
                params: shaderParams(o["params"]),
                textures: (o["textures"]?.object ?? [:]).compactMap { k, v in v.string.map { (k, $0) } }.sorted { $0.name < $1.name }
            ))
        case "particles":
            content = .particles(particles(o))
        default:
            return nil
        }
        return LayerSpec(
            id: id,
            content: content,
            opacity: min(max(o["opacity"]?.number ?? 1, 0), 1),
            visible: o["visible"]?.bool ?? true,
            blend: Blend(rawValue: o["blend"]?.string ?? "") ?? .normal,
            rect: NormRect(o["rect"]) ?? .full,
            fit: Fit(rawValue: o["fit"]?.string ?? "") ?? .fill,
            parallax: o["parallax"]?.number ?? 0,
            daypart: Daypart(rawValue: o["daypart"]?.string ?? "") ?? .always
        )
    }

    static func shaderParams(_ json: JSONValue?) -> [ShaderParam] {
        (json?.object ?? [:]).compactMap { name, decl -> ShaderParam? in
            guard let type = ParamType(rawValue: decl["type"]?.string ?? "float") else { return nil }
            return ShaderParam(name: name, type: type, value: decl["value"] ?? .null)
        }
        .sorted { $0.name < $1.name }
    }

    static func particles(_ o: [String: JSONValue]) -> ParticleSpec {
        let base = ParticlePresets.base
        func range(_ k: String) -> Range2 { Range2(o[k]) ?? Range2(base[k]!)! }
        func num(_ k: String) -> Double { o[k]?.number ?? base[k]!.number! }
        func vec(_ k: String) -> SIMD2<Double> { SIMD2<Double>(o[k]) ?? SIMD2<Double>(base[k]!)! }
        let color = RGBA(o["color"]) ?? .white
        return ParticleSpec(
            count: JSONValue.number(num("count")).int(in: 0...ParticleSpec.maxCount) ?? 0,
            area: NormRect(o["area"]) ?? .full,
            mask: o["mask"]?.string,
            lifetime: range("lifetime"),
            speed: range("speed"),
            direction: num("direction"),
            spread: num("spread"),
            gravity: vec("gravity"),
            wind: vec("wind"),
            turbulence: num("turbulence"),
            turbulenceScale: num("turbulenceScale"),
            size: range("size"),
            color: color,
            colorEnd: RGBA(o["colorEnd"]) ?? color,
            fade: range("fade"),
            twinkle: num("twinkle"),
            shape: ParticleShape(rawValue: o["shape"]?.string ?? "") ?? .dot,
            texture: o["texture"]?.string,
            spin: range("spin"),
            stretch: num("stretch"),
            mouse: num("mouse")
        )
    }
}
