import AppKit
import Foundation

/// `MacPaper <command> …` — authoring tools that run without the UI.
@MainActor
enum CLI {
    static let commands: Set<String> = ["validate", "render", "poster", "bench", "new", "create", "help", "--help"]

    /// Returns an exit code when the arguments name a command, nil to launch the app normally.
    static func runIfRequested() -> Int32? {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, commands.contains(cmd) else { return nil }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "validate": return validate(rest)
        case "render": return render(rest)
        case "poster": return poster(rest)
        case "bench": return bench(rest)
        case "new": return scaffold(rest)
        case "create": return create(rest)
        default:
            print(usage)
            return 0
        }
    }

    static let usage = """
    usage:
      MacPaper validate <package>
      MacPaper render   <package> --out <file.png|jpg|heic> [--size WxH] [--time seconds] [--set control=value …]
      MacPaper poster   <package>
      MacPaper bench    <package> [--size WxH] [--frames N]
      MacPaper new      <path.macpaper> [--template shader|video|image] [--title "Name"]
      MacPaper create   <video…|image> --out <folder> [--title "Name"] [--loop seconds] [--quality original|uhd|hd]
                        [--effect <id> …] [--depth subject|none|<depth.png>] [--strength 0.025]
      effects: \(EffectCatalog.all.map(\.id).joined(separator: ", "))
    """

    private static func option(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func options(_ args: [String], _ name: String) -> [String] {
        args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    private static func size(_ args: [String], default d: CGSize) -> CGSize {
        guard let s = option(args, "--size") else { return d }
        let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : d
    }

    private static func load(_ args: [String]) -> Wallpaper? {
        guard let path = args.first, !path.hasPrefix("--") else {
            print(usage)
            return nil
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            return try Wallpaper.load(url)
        } catch {
            print("\(url.lastPathComponent): error: \(error)")
            return nil
        }
    }

    private static func values(_ args: [String], for wp: Wallpaper) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for pair in options(args, "--set") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq])
            let raw = String(pair[pair.index(after: eq)...])
            guard let control = wp.manifest.allControls.first(where: { $0.id == key }) else {
                print("warning: no control \"\(key)\" (controls: \(wp.manifest.allControls.map(\.id).joined(separator: ", ")))")
                continue
            }
            out[key] = control.value(fromUserInput: raw)
        }
        return out
    }

    private static func validate(_ args: [String]) -> Int32 {
        guard let wp = load(args) else { return 1 }
        var issues: [Issue] = []
        var finished = false
        Task {
            issues = await Validator.validate(wp)
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        for i in issues { print(i.description) }
        let errors = issues.filter { $0.severity == .error }.count
        print(errors == 0 ? "✓ \(wp.title): valid (\(issues.count) warning\(issues.count == 1 ? "" : "s"))" : "✗ \(wp.title): \(errors) error\(errors == 1 ? "" : "s")")
        return errors == 0 ? 0 : 1
    }

    private static func render(_ args: [String]) -> Int32 {
        guard let wp = load(args) else { return 1 }
        guard let out = option(args, "--out") else { print("--out is required"); return 1 }
        let r = OffscreenRenderer(wallpaper: wp, values: values(args, for: wp), size: size(args, default: wp.manifest.canvas))
        defer { r.tearDown() }
        if !r.waitUntilReady() { print("warning: not everything loaded in time") }
        for issue in r.session.issues { print("warning: \(issue)") }
        let t = Double(option(args, "--time") ?? "0") ?? 0
        if t > 0 {
            // Run the simulation up to `t` so particles and video are where they'd be live.
            r.setPlaying(true)
            var elapsed = 0.0
            while elapsed < t {
                let step = min(1.0 / 30, t - elapsed)
                r.render(time: elapsed, dt: step)
                elapsed += step
            }
            r.setPlaying(false)
        }
        let timing = r.render(time: t, dt: 0)
        guard let image = r.image() else { print("error: render failed"); return 1 }
        do {
            try OffscreenRenderer.write(image, to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        print(String(format: "wrote %@ (%.0fx%.0f, %.2f ms GPU)", out, r.size.width, r.size.height, timing.gpuMs))
        return 0
    }

    private static func poster(_ args: [String]) -> Int32 {
        guard let wp = load(args) else { return 1 }
        var code: Int32?
        Task {
            do {
                let url = try await PosterMaker.make(for: wp)
                print("wrote \(url.path)")
                code = 0
            } catch {
                print("error: \(error.localizedDescription)")
                code = 1
            }
        }
        while code == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code!
    }

    private static func bench(_ args: [String]) -> Int32 {
        guard let wp = load(args) else { return 1 }
        let size = size(args, default: CGSize(width: 5120, height: 2880))
        let frames = Int(option(args, "--frames") ?? "300") ?? 300
        let r = OffscreenRenderer(wallpaper: wp, values: values(args, for: wp), size: size)
        defer { r.tearDown() }
        _ = r.waitUntilReady()
        r.setPlaying(true)
        for _ in 0..<10 { r.render(dt: 1.0 / 60) }
        var cpu = 0.0, gpu = 0.0
        let start = CACurrentMediaTime()
        for _ in 0..<frames {
            let t = r.render(dt: 1.0 / 60)
            cpu += t.cpuMs
            gpu += t.gpuMs
            RunLoop.main.run(until: Date())
        }
        let wall = (CACurrentMediaTime() - start) * 1000 / Double(frames)
        print(String(format: "%@ at %.0fx%.0f: %.2f ms GPU, %.2f ms CPU encode, %.2f ms wall per frame", wp.title, size.width, size.height, gpu / Double(frames), cpu / Double(frames), wall))
        return 0
    }

    private static func scaffold(_ args: [String]) -> Int32 {
        guard let path = args.first, !path.hasPrefix("--") else { print(usage); return 1 }
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if url.pathExtension != Manifest.packageExtension { url.appendPathExtension(Manifest.packageExtension) }
        let template = option(args, "--template") ?? "shader"
        let title = option(args, "--title") ?? url.deletingPathExtension().lastPathComponent
        do {
            try Scaffold.create(at: url, template: template, title: title)
            print("created \(url.path)")
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }
}

extension CLI {
    fileprivate static func create(_ args: [String]) -> Int32 {
        var inputs: [URL] = []
        var i = 0
        while i < args.count, !args[i].hasPrefix("--") {
            inputs.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
            i += 1
        }
        guard !inputs.isEmpty, let out = option(args, "--out") else { print(usage); return 1 }
        var result: Int32 = 0
        var finished = false
        Task {
            defer { finished = true }
            guard let draft = await Creator.draft(for: inputs) else {
                print("error: no videos or images among the inputs")
                result = 1
                return
            }
            if let t = option(args, "--title") { draft.title = t }
            if let l = option(args, "--loop").flatMap(Double.init) { draft.loopCrossfade = l }
            if let q = option(args, "--quality").flatMap(VideoQuality.init) { draft.quality = q }
            if let s = option(args, "--strength").flatMap(Double.init) { draft.depthStrength = s }
            switch option(args, "--depth") {
            case "none": draft.depthMode = .none
            case "subject", nil: draft.depthMode = .subject
            case let path?:
                draft.depthMode = .file
                draft.depthFile = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            for id in options(args, "--effect") {
                guard let def = EffectCatalog.definition(id) else {
                    print("error: unknown effect \(id)")
                    result = 1
                    return
                }
                draft.add(def)
            }
            do {
                let made = try await Creator.make(draft) { p, s in print(String(format: "[%3.0f%%] %@", p * 100, s)) }
                let dest = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).appendingPathComponent(made.lastPathComponent)
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: made, to: dest)
                print("created \(dest.path)")
            } catch {
                print("error: \(error.localizedDescription)")
                result = 1
            }
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return result
    }
}

enum Scaffold {
    static let exampleShader = """
    // Everything below `effect` is yours. See FORMAT.md › Shaders for Pixel, Frame and Inputs.
    float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
        float2 p = px.uv * float2(mp_aspect(frame), 1.0) * params.scale;
        float t = frame.time * params.speed;
        float n = mp_fbm(p + float2(t * 0.1, t * 0.05), 5);
        float glow = smoothstep(0.35, 0.9, mp_fbm(p * 1.7 - float2(0.0, t * 0.08) + n, 4));
        float3 col = mix(params.deep.rgb, params.bright.rgb, glow);
        col += 0.15 * frame.audioLevel * params.bright.rgb;
        return float4(col, 1.0);
    }
    """

    static func create(at url: URL, template: String, title: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        var manifest: [String: JSONValue] = [
            "format": 1,
            "id": .string(UUID().uuidString),
            "title": .string(title),
            "canvas": .object(["width": 3840, "height": 2160]),
            "fps": 30,
        ]
        switch template {
        case "video":
            try fm.createDirectory(at: url.appendingPathComponent("media"), withIntermediateDirectories: true)
            manifest["layers"] = .array([.object(["id": "base", "type": "video", "src": "media/base.mov"])])
            manifest["controls"] = .array([])
        case "image":
            try fm.createDirectory(at: url.appendingPathComponent("images"), withIntermediateDirectories: true)
            manifest["drift"] = 0.4
            manifest["layers"] = .array([.object(["id": "plate", "type": "image", "src": "images/plate.heic", "depth": "images/plate-depth.png", "depthStrength": 0.025])])
            manifest["controls"] = .array([])
        default:
            try fm.createDirectory(at: url.appendingPathComponent("shaders"), withIntermediateDirectories: true)
            try exampleShader.write(to: url.appendingPathComponent("shaders/main.metal"), atomically: true, encoding: .utf8)
            manifest["layers"] = .array([.object([
                "id": "main", "type": "shader", "src": "shaders/main.metal",
                "params": .object([
                    "speed": .object(["type": "float", "value": 0.6]),
                    "scale": .object(["type": "float", "value": 2.5]),
                    "deep": .object(["type": "color", "value": "#0b1030"]),
                    "bright": .object(["type": "color", "value": "#58c4ff"]),
                ]),
            ])])
            manifest["controls"] = .array([
                .object(["id": "speed", "type": "slider", "label": "Speed", "min": 0, "max": 2, "unit": "x", "target": "main.params.speed"]),
                .object(["id": "scale", "type": "slider", "label": "Scale", "min": 0.5, "max": 6, "target": "main.params.scale"]),
                .object(["id": "deep", "type": "color", "label": "Shadows", "target": "main.params.deep"]),
                .object(["id": "bright", "type": "color", "label": "Highlights", "target": "main.params.bright"]),
            ])
        }
        try JSONValue.object(manifest).encoded().write(to: url.appendingPathComponent(Manifest.fileName))
    }
}
