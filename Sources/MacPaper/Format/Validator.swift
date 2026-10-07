import AVFoundation
import Foundation

struct Issue: Hashable, Sendable, Identifiable, Codable {
    enum Severity: String, Sendable, Codable { case error, warning }
    var severity: Severity
    var path: String
    var message: String
    var id: String { "\(severity.rawValue)|\(path)|\(message)" }

    var description: String { path.isEmpty ? "\(severity.rawValue): \(message)" : "\(path): \(severity.rawValue): \(message)" }

    static func error(_ path: String, _ message: String) -> Issue { Issue(severity: .error, path: path, message: message) }
    static func warning(_ path: String, _ message: String) -> Issue { Issue(severity: .warning, path: path, message: message) }
}

enum PropType: Hashable {
    case number, optionalNumber, bool, file, color, vec2, rect, range, oneOf([String])

    var title: String {
        switch self {
        case .number: "a number"
        case .optionalNumber: "a number or null"
        case .bool: "true or false"
        case .file: "a file path"
        case .color: "a colour"
        case .vec2: "[x, y]"
        case .rect: "[x, y, w, h]"
        case .range: "[min, max]"
        case .oneOf(let v): "one of " + v.joined(separator: ", ")
        }
    }

    func accepts(_ v: JSONValue) -> Bool {
        switch self {
        case .number: v.number != nil
        case .optionalNumber: v.number != nil || v.isNull
        case .bool: v.bool != nil
        case .file: v.string != nil
        case .color: RGBA(v) != nil
        case .vec2: v.numbers?.count == 2
        case .rect: v.numbers?.count == 4
        case .range: v.number != nil || v.numbers?.count == 2
        case .oneOf(let allowed): v.string.map(allowed.contains) ?? false
        }
    }
}

enum Validator {
    static let identifier = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_-]*$")
    static let mslIdentifier = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")

    static func isIdentifier(_ s: String, msl: Bool = false) -> Bool {
        let r = msl ? mslIdentifier : identifier
        return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static let common: [String: PropType] = [
        "opacity": .number, "visible": .bool, "parallax": .number, "rect": .rect,
        "blend": .oneOf(Blend.allCases.map(\.rawValue)), "fit": .oneOf(["fill", "fit", "stretch"]),
        "daypart": .oneOf(["always", "day", "night"]),
    ]

    static let particleProps: [String: PropType] = [
        "preset": .oneOf(ParticlePresets.names), "count": .number, "area": .rect, "mask": .file, "lifetime": .range,
        "speed": .range, "direction": .number, "spread": .number, "gravity": .vec2, "wind": .vec2,
        "turbulence": .number, "turbulenceScale": .number, "size": .range, "color": .color, "colorEnd": .color,
        "fade": .range, "twinkle": .number, "shape": .oneOf(ParticleShape.allCases.map(\.rawValue)),
        "texture": .file, "spin": .range, "stretch": .number, "mouse": .number,
    ]

    static func props(for type: String) -> [String: PropType] {
        var p = common
        switch type {
        case "video": p.merge(["src": .file, "rate": .number, "freeze": .optionalNumber, "volume": .number, "intro": .bool, "crossfade": .number]) { a, _ in a }
        case "image": p.merge(["src": .file, "depth": .file, "depthStrength": .number]) { a, _ in a }
        case "shader": p["src"] = .file
        case "particles": p.merge(particleProps) { a, _ in a }
        default: break
        }
        return p
    }

    static func paramPropType(_ t: ParamType) -> PropType {
        switch t {
        case .float: .number
        case .float2: .vec2
        case .float3, .float4: .rect
        case .color: .color
        case .int: .number
        case .bool: .bool
        }
    }

    static func propType(of path: String, in m: Manifest) -> PropType? {
        let parts = PropertyPath.components(path)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "scene":
            return ["drift": .number, "background": .color][parts[1]].flatMap { $0 }
        case "audio":
            return parts[1] == "volume" ? .number : nil
        case "captions":
            if parts[1] == "idleEvery" { return .number }
            guard parts[1] == "lang" else { return nil }
            var langs: Set<String> = []
            let byClip = m.raw["captions"]?["lines"]?.object ?? [:]
            for lines in byClip.values {
                for key in ["enter", "held", "restored", "idle"] {
                    for line in lines[key]?.array ?? [] { langs.formUnion(Array((line.object ?? [:]).keys)) }
                }
            }
            return .oneOf(["auto", "off"] + langs.sorted())
        default:
            guard let layer = m.layers.first(where: { $0["id"]?.string == parts[0] }), let type = layer["type"]?.string else { return nil }
            if type == "shader", parts.count == 3 {
                if parts[1] == "params" {
                    guard let decl = layer["params"]?[parts[2]], let t = ParamType(rawValue: decl["type"]?.string ?? "float") else { return nil }
                    return paramPropType(t)
                }
                if parts[1] == "textures" { return layer["textures"]?[parts[2]] != nil ? .file : nil }
                return nil
            }
            guard parts.count == 2 else { return nil }
            return props(for: type)[parts[1]]
        }
    }

    /// Structural checks that need no GPU.
    static func check(_ m: Manifest, package: URL) -> [Issue] {
        var issues: [Issue] = []
        let wp = Wallpaper(id: m.id, url: package, manifest: m, stamp: .distantPast, linked: false)
        func file(_ path: String?, _ at: String) {
            guard let path else { return }
            guard let url = wp.file(path) else {
                issues.append(.error(at, "\(path) points outside the package"))
                return
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                issues.append(.error(at, "\(path) not found"))
            }
        }
        if UUID(uuidString: m.id) == nil { issues.append(.warning("id", "should be a UUID so it never collides with another wallpaper")) }
        if let poster = m.poster, wp.file(poster) == nil {
            issues.append(.error("poster", "\(poster) points outside the package"))
        } else if wp.packagePosterURL == nil {
            issues.append(.warning("poster", "no poster — MacPaper renders one from frame 0"))
        }
        if m.layers.isEmpty { issues.append(.error("layers", "a wallpaper needs at least one layer")) }
        if let bg = m.raw["background"], RGBA(bg) == nil { issues.append(.error("background", "must be a colour")) }
        if let c = m.raw["captions"] {
            if let video = c["video"]?.string {
                if !m.layers.contains(where: { $0["id"]?.string == video && $0["type"]?.string == "video" }) {
                    issues.append(.error("captions.video", "must name a video layer"))
                }
            } else {
                issues.append(.error("captions.video", "required: the id of the video layer the lines follow"))
            }
            for src in (c["lines"]?.object ?? [:]).keys { file(src, "captions.lines") }
        }

        var ids: Set<String> = []
        for (i, layer) in m.layers.enumerated() {
            let at = "layers[\(i)]"
            guard let id = layer["id"]?.string, isIdentifier(id) else {
                issues.append(.error("\(at).id", "required; letters, digits, - and _"))
                continue
            }
            if !ids.insert(id).inserted { issues.append(.error("\(at).id", "duplicate id \"\(id)\"")) }
            guard let type = layer["type"]?.string, ["video", "image", "shader", "particles"].contains(type) else {
                issues.append(.error("\(at).type", "must be video, image, shader or particles"))
                continue
            }
            let known = props(for: type).merging(["id": .file, "type": .file, "params": .file, "textures": .file, "function": .file]) { a, _ in a }
            for (key, value) in layer {
                guard let t = known[key] else {
                    issues.append(.warning("\(at).\(key)", "unknown property for a \(type) layer"))
                    continue
                }
                if !["id", "type", "params", "textures", "function"].contains(key), !t.accepts(value) {
                    issues.append(.error("\(at).\(key)", "must be \(t.title)"))
                }
            }
            if type != "particles", layer["src"]?.string == nil { issues.append(.error("\(at).src", "required")) }
            for key in ["src", "depth", "mask", "texture"] { file(layer[key]?.string, "\(at).\(key)") }
            if ["shader", "particles"].contains(type), layer["rect"] != nil {
                issues.append(.warning("\(at).rect", "has no effect on a \(type) layer, which always covers the canvas"))
            }
            if type == "shader", let f = layer["function"], f.string.map({ isIdentifier($0, msl: true) }) != true {
                issues.append(.error("\(at).function", "must be a plain Metal function name"))
            }
            if type == "particles", let n = layer["count"]?.number, n > Double(ParticleSpec.maxCount) {
                issues.append(.warning("\(at).count", "capped at \(ParticleSpec.maxCount)"))
            }
            if type == "shader" {
                for (name, decl) in layer["params"]?.object ?? [:] {
                    let p = "\(at).params.\(name)"
                    if !isIdentifier(name, msl: true) { issues.append(.error(p, "must be a valid Metal identifier")) }
                    guard let t = ParamType(rawValue: decl["type"]?.string ?? "float") else {
                        issues.append(.error("\(p).type", "must be one of " + ParamType.allCases.map(\.rawValue).joined(separator: ", ")))
                        continue
                    }
                    if let v = decl["value"], !paramPropType(t).accepts(v), !(t == .float4 && v.numbers?.count == 4), !(t == .float3 && v.numbers?.count == 3) {
                        issues.append(.error("\(p).value", "must be \(paramPropType(t).title)"))
                    }
                }
                for (name, path) in layer["textures"]?.object ?? [:] {
                    let p = "\(at).textures.\(name)"
                    if !isIdentifier(name, msl: true) || ShaderProgram.reservedNames.contains(name) {
                        issues.append(.error(p, "must be a Metal identifier other than source, linear, repeat, nearest"))
                    }
                    file(path.string, p)
                }
            }
        }

        var controlIDs: Set<String> = []
        let controls = m.allControls
        for c in controls {
            let at = "controls.\(c.id)"
            if !isIdentifier(c.id) { issues.append(.error(at, "id must use letters, digits, - and _")) }
            if !controlIDs.insert(c.id).inserted { issues.append(.error(at, "duplicate control id")) }
            if c.targets.isEmpty, !(c.kind == .choice && c.options.contains { !$0.set.isEmpty }) {
                issues.append(.warning(at, "has no target, so it changes nothing"))
            }
            for t in c.targets {
                guard let type = propType(of: t, in: m) else {
                    issues.append(.error("\(at).target", "\(t) doesn't name a property"))
                    continue
                }
                switch c.kind {
                case .toggle where type != .bool: issues.append(.error("\(at).target", "a toggle needs a true/false property; \(t) is \(type.title)"))
                case .slider where type != .number && type != .optionalNumber: issues.append(.error("\(at).target", "a slider needs a number property; \(t) is \(type.title)"))
                case .color where type != .color && type != .rect: issues.append(.error("\(at).target", "a colour control needs a colour property; \(t) is \(type.title)"))
                case .point where type != .vec2: issues.append(.error("\(at).target", "a point control needs an [x, y] property; \(t) is \(type.title)"))
                case .choice:
                    for o in c.options where !type.accepts(o.value) {
                        issues.append(.error("\(at).options", "\(o.value.display) isn't valid for \(t) (needs \(type.title))"))
                    }
                    if type == .file { for o in c.options { file(o.value.string, "\(at).options") } }
                default: break
                }
            }
            for o in c.options {
                file(o.thumb, "\(at).options.thumb")
                for (path, v) in o.set {
                    guard let type = propType(of: path, in: m) else {
                        issues.append(.error("\(at).options.set", "\(path) doesn't name a property"))
                        continue
                    }
                    if !type.accepts(v) { issues.append(.error("\(at).options.set", "\(path) needs \(type.title)")) }
                    if type == .file { file(v.string, "\(at).options.set") }
                }
            }
        }
        for c in controls {
            if let cycle = c.cycle {
                let valid = cycle == .string("clip") || (cycle.number ?? 0) > 0
                if c.kind != .choice { issues.append(.error("controls.\(c.id).cycle", "only choice controls can change automatically")) }
                else if !valid { issues.append(.error("controls.\(c.id).cycle", "must be \"clip\" or a number of minutes")) }
            }
            for key in c.visibleWhen.keys where !controlIDs.contains(key) {
                issues.append(.error("controls.\(c.id).visibleWhen", "refers to unknown control \"\(key)\""))
            }
        }
        return issues
    }

    /// Full validation: structure, video decodability and shader compilation.
    @MainActor
    static func validate(_ wallpaper: Wallpaper) async -> [Issue] {
        let m = wallpaper.manifest
        var issues = check(m, package: wallpaper.url)
        let device = GPU.shared.device
        var compiled: Set<String> = []
        for layer in m.layers where layer["type"]?.string == "shader" {
            guard let decoded = LayerDecoder.decode(layer), case .shader(let spec) = decoded.content,
                  let url = wallpaper.file(spec.src), let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let key = ShaderProgram.cacheKey(spec, source: source)
            guard compiled.insert(key).inserted else { continue }
            do {
                _ = try await ShaderProgram.shared(spec: spec, source: source, fileName: spec.src, device: device)
            } catch let e as ShaderCompileError {
                for d in e.diagnostics { issues.append(.error(d.line > 0 ? "\(d.file):\(d.line):\(d.column)" : d.file, d.message)) }
            } catch {
                issues.append(.error(spec.src, error.localizedDescription))
            }
        }
        var videoFiles: Set<String> = []
        for layer in m.layers where layer["type"]?.string == "video" {
            if let s = layer["src"]?.string { videoFiles.insert(s) }
        }
        for c in m.allControls {
            for t in c.targets where propType(of: t, in: m) == .file && PropertyPath.components(t).count == 2 {
                if let l = m.layers.first(where: { $0["id"]?.string == PropertyPath.components(t)[0] }), l["type"]?.string == "video" {
                    for o in c.options { if let s = o.value.string { videoFiles.insert(s) } }
                }
            }
        }
        for path in videoFiles.sorted() {
            guard let url = wallpaper.file(path), FileManager.default.fileExists(atPath: url.path) else { continue }
            issues += await checkVideo(url, path: path)
        }
        return issues
    }

    static func checkVideo(_ url: URL, path: String) async -> [Issue] {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable), let track = try await asset.loadTracks(withMediaType: .video).first else {
                return [.error(path, "can't be decoded on macOS — use HEVC or H.264 in .mov/.mp4")]
            }
            let descs = try await track.load(.formatDescriptions)
            let codecs = descs.map { CMFormatDescriptionGetMediaSubType($0) }
            let ok: Set<FourCharCode> = [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264, kCMVideoCodecType_HEVCWithAlpha]
            if !codecs.contains(where: ok.contains) {
                return [.warning(path, "not HEVC or H.264 — it may decode in software and cost battery")]
            }
            let size = try await track.load(.naturalSize)
            if max(size.width, size.height) > 6200 {
                return [.warning(path, "larger than 6K; hardware decoders top out around 8K and 4K–6K looks identical on a desktop")]
            }
        } catch {
            return [.error(path, error.localizedDescription)]
        }
        return []
    }
}
