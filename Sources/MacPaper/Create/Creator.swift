import AppKit
import Observation
import UniformTypeIdentifiers

struct DraftSource: Identifiable {
    let id = UUID()
    let url: URL
    let isVideo: Bool
    var label: String
    var size: CGSize = .zero
    var duration: Double = 0
    var fps: Double = 30
    var playable = true
    var efficient = true
    var preview: CGImage?
}

struct DraftEffect: Identifiable {
    var id: String
    var definition: EffectDefinition
    var mask: CGImage?
}

enum DepthMode: String, CaseIterable, Identifiable {
    case none, subject, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .subject: "Automatic"
        case .file: "Depth map…"
        }
    }
}

@MainActor
@Observable
final class CreatorDraft {
    var title: String
    var sources: [DraftSource]
    var loopCrossfade: Double = 0
    var quality: VideoQuality = .uhd
    var depthMode: DepthMode = .subject
    var depthFile: URL?
    var depthStrength: Double = 0.025
    var drift: Double = 0.35
    var effects: [DraftEffect] = []
    var focus = SIMD2<Double>(0.5, 0.5)
    var subjectMask: CGImage?
    var analyzing = true

    private let originalTitle: String
    private let originalSources: Int

    init(title: String, sources: [DraftSource]) {
        self.title = title
        self.sources = sources
        originalTitle = title
        originalSources = sources.count
    }

    /// Whether discarding would throw away choices the user made.
    var isEdited: Bool {
        title != originalTitle || sources.count != originalSources || !effects.isEmpty || depthFile != nil
            || loopCrossfade != 0 || quality != .uhd || depthMode != .subject || depthStrength != 0.025 || drift != 0.35
    }

    var isVideo: Bool { sources.first?.isVideo ?? false }
    var preview: CGImage? { sources.first?.preview }
    var canvas: CGSize {
        guard let s = sources.first?.size, s.width > 0 else { return CGSize(width: 3840, height: 2160) }
        let cap = isVideo ? min(quality.maxSide, 6144) : 6144
        let k = min(1, cap / max(s.width, s.height))
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    func add(_ def: EffectDefinition) {
        var id = def.id
        var n = 2
        while effects.contains(where: { $0.id == id }) {
            id = "\(def.id)-\(n)"
            n += 1
        }
        effects.append(DraftEffect(id: id, definition: def))
    }
}

/// Turns videos and images into `.macpaper` packages: transcoding, seamless loops, depth, effects and posters.
@MainActor
@Observable
final class Creator {
    var draft: CreatorDraft?
    private(set) var busy = false
    private(set) var progress: Double = 0
    private(set) var status = ""
    var error: String?
    @ObservationIgnored var onCreated: ((URL) async throws -> Void)?
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    func begin(with urls: [URL]) {
        let media = urls.filter { MediaTools.isVideo($0) || MediaTools.isImage($0) }
        guard !media.isEmpty else {
            error = "Drop videos (MP4, MOV, WebM) or images (HEIC, PNG, JPEG)."
            return
        }
        let videos = media.filter(MediaTools.isVideo)
        let chosen = videos.isEmpty ? [media[0]] : videos
        let sources = chosen.map { DraftSource(url: $0, isVideo: MediaTools.isVideo($0), label: Self.label(for: $0)) }
        let draft = CreatorDraft(title: Self.label(for: chosen[0]), sources: sources)
        self.draft = draft
        error = nil
        Task { await Self.analyze(draft) }
    }

    static func draft(for urls: [URL]) async -> CreatorDraft? {
        let media = urls.filter { MediaTools.isVideo($0) || MediaTools.isImage($0) }
        guard !media.isEmpty else { return nil }
        let videos = media.filter(MediaTools.isVideo)
        let chosen = videos.isEmpty ? [media[0]] : videos
        let draft = CreatorDraft(title: label(for: chosen[0]), sources: chosen.map { DraftSource(url: $0, isVideo: MediaTools.isVideo($0), label: label(for: $0)) })
        await analyze(draft)
        return draft
    }

    func cancel() {
        cancelBuild()
        draft = nil
        error = nil
    }

    /// Stops a build in progress and keeps the draft, so it can be changed and built again.
    func cancelBuild() {
        buildTask?.cancel()
        buildTask = nil
        busy = false
        progress = 0
        status = ""
    }

    static func label(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    static func analyze(_ draft: CreatorDraft) async {
        for i in draft.sources.indices {
            let s = draft.sources[i]
            if s.isVideo {
                let info = await MediaTools.info(s.url)
                draft.sources[i].size = info.size
                draft.sources[i].duration = info.duration
                draft.sources[i].fps = info.fps
                draft.sources[i].playable = info.playable
                draft.sources[i].efficient = info.isEfficientCodec
                draft.sources[i].preview = info.playable ? await MediaTools.frame(s.url, maxSide: 1600) : nil
                if !info.playable, i == 0 {
                    draft.sources[i].preview = await ffmpegPreview(s.url)
                }
            } else {
                let url = s.url
                let image = await Task.detached { MediaTools.loadImage(url, maxSide: 1600) }.value
                let full = await Task.detached { MediaTools.loadImage(url) }.value
                draft.sources[i].preview = image
                draft.sources[i].size = full.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            }
        }
        if let preview = draft.preview {
            let (mask, focus) = await Task.detached { (MediaTools.subjectMask(preview), MediaTools.focusPoint(preview)) }.value
            draft.subjectMask = mask
            if let focus { draft.focus = focus }
        }
        if draft.isVideo, draft.sources.contains(where: { !$0.playable }) { draft.quality = .uhd }
        draft.analyzing = false
    }

    private static func ffmpegPreview(_ url: URL) async -> CGImage? {
        guard let ffmpeg = MediaTools.ffmpeg else { return nil }
        let out = Paths.cache.appendingPathComponent("preview-\(UUID().uuidString).jpg")
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-y", "-v", "error", "-i", url.path, "-frames:v", "1", "-vf", "scale=1600:-2", out.path]
        try? p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in p.terminationHandler = { _ in c.resume() } }
        defer { try? FileManager.default.removeItem(at: out) }
        return MediaTools.loadImage(out)
    }

    // MARK: Build

    /// The draft is only cleared once the package is safely in the library.
    func build() {
        guard let draft, !busy else { return }
        busy = true
        progress = 0
        error = nil
        buildTask = Task {
            do {
                let url = try await Self.make(draft) { [weak self] p, s in
                    Task { @MainActor in
                        guard let self, self.busy else { return }
                        self.progress = p
                        self.status = s
                    }
                }
                try Task.checkCancellation()
                do {
                    try await onCreated?(url)
                } catch {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    throw error
                }
                busy = false
                buildTask = nil
                if self.draft === draft { self.draft = nil }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                busy = false
                buildTask = nil
                self.error = AppModel.describe(error)
            }
        }
    }

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let base = s.lowercased().replacingOccurrences(of: " ", with: "-").unicodeScalars.filter { allowed.contains($0) }
        let out = String(String.UnicodeScalarView(base)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "clip" : String(out.prefix(40))
    }

    /// Writes the package into a temporary folder and returns it. Usable headlessly (see `CLI create`).
    static func make(_ draft: CreatorDraft, report: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = Paths.ensure(Paths.cache.appendingPathComponent("Creating/\(UUID().uuidString)", isDirectory: true))
        do {
            return try await make(draft, in: work, report: report)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private static func make(_ draft: CreatorDraft, in work: URL, report: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let title = draft.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : draft.title
        let pkg = work.appendingPathComponent(slug(title)).appendingPathExtension(Manifest.packageExtension)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        var layers: [JSONValue] = []
        var controls: [JSONValue] = []
        var fps = 30
        let steps = Double(draft.sources.count + 2)

        if draft.isVideo {
            try fm.createDirectory(at: pkg.appendingPathComponent("media"), withIntermediateDirectories: true)
            var options: [JSONValue] = []
            var used: Set<String> = []
            for (i, source) in draft.sources.enumerated() {
                var name = slug(source.label)
                while used.contains(name) { name += "-\(i + 1)" }
                used.insert(name)
                try Task.checkCancellation()
                let base = Double(i) / steps
                report(base, "Preparing \(source.label)…")
                var input = source.url
                if !source.playable {
                    let converted = work.appendingPathComponent("\(name)-converted.mov")
                    report(base, "Converting \(source.label) with ffmpeg…")
                    try await MediaTools.transcodeWithFFmpeg(source.url, to: converted)
                    input = converted
                }
                let info = await MediaTools.info(input)
                fps = max(fps, min(60, Int(info.fps.rounded())))
                let needsExport = draft.loopCrossfade > 0 || !info.isEfficientCodec || max(info.size.width, info.size.height) > draft.quality.maxSide + 1
                let ext = needsExport ? "mov" : input.pathExtension.lowercased()
                let rel = "media/\(name).\(ext)"
                let out = pkg.appendingPathComponent(rel)
                if needsExport {
                    try await MediaTools.export(input, to: out, quality: draft.quality, crossfade: draft.loopCrossfade) { p in
                        report(base + p / steps, "Encoding \(source.label)…")
                    }
                } else {
                    try fm.copyItem(at: input, to: out)
                }
                if draft.sources.count > 1 {
                    try fm.createDirectory(at: pkg.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
                    if let thumb = await MediaTools.frame(out, maxSide: 480) {
                        try MediaTools.write(thumb, to: pkg.appendingPathComponent("thumbs/\(name).jpg"), type: .jpeg, quality: 0.85)
                    }
                    options.append(.object(["label": .string(source.label), "value": .string(rel), "thumb": .string("thumbs/\(name).jpg")]))
                }
                if i == 0 {
                    layers.append(.object(["id": "base", "type": "video", "src": .string(rel)]))
                }
            }
            if options.count > 1 {
                controls.append(.object([
                    "id": "variant", "type": "choice", "style": "gallery", "label": "Variant", "quick": true,
                    "target": "base.src", "options": .array(options),
                ]))
            }
        } else if let source = draft.sources.first {
            report(0.1, "Preparing image…")
            try fm.createDirectory(at: pkg.appendingPathComponent("images"), withIntermediateDirectories: true)
            let canvas = draft.canvas
            let rel: String
            if max(source.size.width, source.size.height) > 6144 || !["heic", "jpg", "jpeg", "png"].contains(source.url.pathExtension.lowercased()) {
                rel = "images/plate.heic"
                let (src, dest, side) = (source.url, pkg.appendingPathComponent(rel), max(canvas.width, canvas.height))
                try await Task.detached(priority: .userInitiated) {
                    guard let img = MediaTools.loadImage(src, maxSide: side) else { throw MediaError(message: "couldn't read the image") }
                    try MediaTools.write(img, to: dest, type: .heic, quality: 0.92)
                }.value
            } else {
                rel = "images/plate.\(source.url.pathExtension.lowercased())"
                try fm.copyItem(at: source.url, to: pkg.appendingPathComponent(rel))
            }
            var plate: [String: JSONValue] = ["id": "plate", "type": "image", "src": .string(rel)]
            switch draft.depthMode {
            case .subject:
                report(0.3, "Estimating depth…")
                let (src, subject, dest) = (source.url, draft.subjectMask, pkg.appendingPathComponent("images/plate-depth.png"))
                let wrote = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
                    guard let full = MediaTools.loadImage(src, maxSide: 2048),
                          let depth = MediaTools.estimatedDepth(for: full, subject: subject ?? MediaTools.subjectMask(full)) else { return false }
                    try MediaTools.write(depth, to: dest, type: .png)
                    return true
                }.value
                if wrote { plate["depth"] = "images/plate-depth.png" }
            case .file:
                if let d = draft.depthFile {
                    let rel = "images/plate-depth.\(d.pathExtension.lowercased())"
                    try fm.copyItem(at: d, to: pkg.appendingPathComponent(rel))
                    plate["depth"] = .string(rel)
                }
            case .none:
                break
            }
            if plate["depth"] != nil {
                plate["depthStrength"] = .number(draft.depthStrength)
                controls.append(.object(["id": "depth", "type": "slider", "label": "Depth", "min": 0, "max": 0.08, "target": "plate.depthStrength"]))
            }
            layers.append(.object(plate))
        }

        report((steps - 2) / steps, "Adding effects…")
        for effect in draft.effects {
            let (layer, section) = try effectLayer(effect, in: pkg)
            layers.append(layer)
            controls.append(section)
        }
        let manifest: [String: JSONValue] = [
            "format": 1,
            "id": .string(UUID().uuidString),
            "title": .string(title),
            "canvas": .object(["width": .number(draft.canvas.width), "height": .number(draft.canvas.height)]),
            "focus": JSONValue([draft.focus.x, draft.focus.y]),
            "poster": "poster.heic",
            "fps": .number(Double(fps)),
            "drift": .number(draft.isVideo ? 0 : draft.drift),
            "layers": .array(layers),
            "controls": .array(controls),
        ]
        try JSONValue.object(manifest).encoded().write(to: pkg.appendingPathComponent(Manifest.fileName))

        try Task.checkCancellation()
        report((steps - 1) / steps, "Rendering poster…")
        let wp = try Wallpaper.load(pkg)
        let issues = Validator.check(wp.manifest, package: pkg).filter { $0.severity == .error }
        if let first = issues.first { throw MediaError(message: first.description) }
        _ = try await PosterMaker.make(for: wp)
        report(1, "Done")
        return pkg
    }

    private static func effectLayer(_ effect: DraftEffect, in pkg: URL) throws -> (JSONValue, JSONValue) {
        let def = effect.definition
        let fm = FileManager.default
        var layer: [String: JSONValue] = ["id": .string(effect.id)]
        var maskRel: String?
        if def.usesMask {
            try fm.createDirectory(at: pkg.appendingPathComponent("masks"), withIntermediateDirectories: true)
            maskRel = "masks/\(effect.id).png"
            let mask = effect.mask ?? MediaTools.solidMask(width: 64, height: 36)!
            try MediaTools.write(mask, to: pkg.appendingPathComponent(maskRel!), type: .png)
        }
        if def.blend != .normal { layer["blend"] = .string(def.blend.rawValue) }
        var knobs: [JSONValue] = [.object(["id": .string("\(effect.id)-on"), "type": "toggle", "label": "On", "target": .string("\(effect.id).visible")])]
        switch def.source {
        case .shader(let file):
            guard let source = EffectCatalog.shaderSource(file) else { throw MediaError(message: "the \(def.name) effect is missing from the app") }
            try fm.createDirectory(at: pkg.appendingPathComponent("shaders"), withIntermediateDirectories: true)
            let rel = "shaders/\(file)"
            if !fm.fileExists(atPath: pkg.appendingPathComponent(rel).path) {
                try source.write(to: pkg.appendingPathComponent(rel), atomically: true, encoding: .utf8)
            }
            layer["type"] = "shader"
            layer["src"] = .string(rel)
            var params: [String: JSONValue] = [:]
            for p in def.params { params[p.name] = .object(["type": .string(p.type.rawValue), "value": p.value]) }
            layer["params"] = .object(params)
            if let maskRel { layer["textures"] = .object(["mask": .string(maskRel)]) }
            for k in def.knobs { knobs.append(knob(k, id: effect.id, target: "\(effect.id).params.\(k.property)")) }
        case .particles(let preset):
            layer["type"] = "particles"
            layer["preset"] = .string(preset)
            if let maskRel { layer["mask"] = .string(maskRel) }
            for k in def.knobs { knobs.append(knob(k, id: effect.id, target: "\(effect.id).\(k.property)")) }
        }
        let section: JSONValue = .object(["type": "section", "label": .string(def.name), "controls": .array(knobs)])
        return (.object(layer), section)
    }

    private static func knob(_ k: EffectDefinition.Knob, id: String, target: String) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string("\(id)-\(k.property)"), "label": .string(k.label), "target": .string(target)]
        switch k.kind {
        case .slider(let min, let max, let unit):
            o["type"] = "slider"
            o["min"] = .number(min)
            o["max"] = .number(max)
            if let unit { o["unit"] = .string(unit) }
        case .color:
            o["type"] = "color"
        case .point:
            o["type"] = "point"
        }
        return .object(o)
    }
}
