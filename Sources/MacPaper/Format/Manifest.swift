import Foundation

struct ManifestError: Error, CustomStringConvertible {
    let path: String
    let message: String
    var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

struct Manifest: Sendable {
    static let fileName = "manifest.json"
    static let packageExtension = "macpaper"

    var raw: [String: JSONValue]
    var id: String
    var title: Localized
    var author: String?
    var description: Localized?
    var tags: [String]
    var canvas: CGSize
    var focus: SIMD2<Double>
    var poster: String?
    var fps: Int
    var layers: [[String: JSONValue]]
    var controls: [Control]

    init(json: JSONValue) throws {
        guard let root = json.object else { throw ManifestError(path: "", message: "manifest must be a JSON object") }
        raw = root
        if let f = root["format"], f != .number(1) {
            throw ManifestError(path: "format", message: "unsupported format \(f.display); this version reads format 1")
        }
        guard let id = root["id"]?.string, !id.isEmpty else { throw ManifestError(path: "id", message: "required (a UUID string)") }
        self.id = id
        title = Localized(root["title"]) ?? Localized("Untitled")
        author = root["author"]?.string
        description = Localized(root["description"])
        tags = root["tags"]?.array?.compactMap(\.string) ?? []
        let w = root["canvas"]?["width"]?.number ?? 3840
        let h = root["canvas"]?["height"]?.number ?? 2160
        guard w >= 16, h >= 16 else { throw ManifestError(path: "canvas", message: "width and height must be at least 16") }
        canvas = CGSize(width: w, height: h)
        focus = SIMD2<Double>(root["focus"]) ?? SIMD2(0.5, 0.5)
        poster = root["poster"]?.string
        fps = root["fps"]?.int(in: 1...240) ?? 30
        guard let layerList = root["layers"]?.array else { throw ManifestError(path: "layers", message: "required (an array)") }
        layers = try layerList.enumerated().map { i, l in
            guard let o = l.object else { throw ManifestError(path: "layers[\(i)]", message: "must be an object") }
            return o
        }
        controls = try (root["controls"]?.array ?? []).enumerated().map { i, c in
            try Control(json: c, path: "controls[\(i)]")
        }
    }

    static func load(from package: URL) throws -> Manifest {
        let url = package.appendingPathComponent(fileName)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ManifestError(path: "", message: "\(fileName) is missing or unreadable")
        }
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch {
            throw ManifestError(path: fileName, message: "invalid JSON — \(Self.describe(error))")
        }
        return try Manifest(json: json)
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let ctx) = error {
            return (ctx.underlyingError as NSError?)?.userInfo["NSDebugDescription"] as? String ?? ctx.debugDescription
        }
        return error.localizedDescription
    }

    var allControls: [Control] {
        controls.flatMap { $0.flattened }
    }

    func layerIndex(_ id: String) -> Int? {
        layers.firstIndex { $0["id"]?.string == id }
    }
}

struct ControlOption: Hashable, Sendable {
    var label: Localized
    var value: JSONValue
    var thumb: String?
    var set: [String: JSONValue]
}

struct Control: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case toggle, slider, choice, color, point, section }
    enum ChoiceStyle: String, Sendable { case menu, segmented, list, gallery }

    var id: String
    var kind: Kind
    var label: Localized
    var help: Localized?
    var targets: [String]
    var defaultValue: JSONValue?
    var visibleWhen: [String: [JSONValue]]
    var quick: Bool
    /// The package's suggested auto-change for a choice: "clip" or a number of minutes.
    var cycle: JSONValue?
    var min: Double
    var max: Double
    var step: Double?
    var unit: String?
    var options: [ControlOption]
    var style: ChoiceStyle
    var alpha: Bool
    var children: [Control]
    var collapsed: Bool

    init(json: JSONValue, path: String) throws {
        guard let o = json.object else { throw ManifestError(path: path, message: "must be an object") }
        guard let typeName = o["type"]?.string, let kind = Kind(rawValue: typeName) else {
            throw ManifestError(path: "\(path).type", message: "must be one of toggle, slider, choice, color, point, section")
        }
        self.kind = kind
        id = o["id"]?.string ?? ""
        if kind != .section, id.isEmpty { throw ManifestError(path: "\(path).id", message: "required") }
        label = Localized(o["label"]) ?? Localized(id)
        help = Localized(o["help"])
        switch o["target"] {
        case .string(let s): targets = [s]
        case .array(let a): targets = a.compactMap(\.string)
        default: targets = []
        }
        defaultValue = o["default"]
        var when: [String: [JSONValue]] = [:]
        for (k, v) in o["visibleWhen"]?.object ?? [:] {
            when[k] = v.array ?? [v]
        }
        visibleWhen = when
        quick = o["quick"]?.bool ?? false
        cycle = o["cycle"]
        min = o["min"]?.number ?? 0
        max = o["max"]?.number ?? 1
        step = o["step"]?.number
        unit = o["unit"]?.string
        options = try (o["options"]?.array ?? []).enumerated().map { i, opt in
            guard let oo = opt.object else { throw ManifestError(path: "\(path).options[\(i)]", message: "must be an object") }
            return ControlOption(
                label: Localized(oo["label"]) ?? Localized(oo["value"]?.display ?? "Option \(i + 1)"),
                value: oo["value"] ?? .number(Double(i)),
                thumb: oo["thumb"]?.string,
                set: oo["set"]?.object ?? [:]
            )
        }
        style = ChoiceStyle(rawValue: o["style"]?.string ?? "") ?? (options.contains { $0.thumb != nil } ? .gallery : .menu)
        alpha = o["alpha"]?.bool ?? false
        children = try (o["controls"]?.array ?? []).enumerated().map { i, c in
            try Control(json: c, path: "\(path).controls[\(i)]")
        }
        collapsed = o["collapsed"]?.bool ?? false
        if kind == .choice, options.isEmpty { throw ManifestError(path: "\(path).options", message: "a choice needs at least one option") }
        if kind == .slider, self.max <= self.min { throw ManifestError(path: "\(path).max", message: "must be greater than min") }
    }

    var flattened: [Control] {
        kind == .section ? children.flatMap(\.flattened) : [self]
    }

    func isVisible(values: [String: JSONValue]) -> Bool {
        visibleWhen.allSatisfy { key, allowed in
            guard let v = values[key] else { return false }
            return allowed.contains(v)
        }
    }

    func option(for value: JSONValue) -> ControlOption? {
        options.first { $0.value == value }
    }

    /// A value a person typed (CLI, URL commands): JSON, or for a choice an option's value or label.
    func value(fromUserInput raw: String) -> JSONValue {
        let parsed = (try? JSONValue.parse(Data(raw.utf8))) ?? .string(raw)
        guard kind == .choice, option(for: parsed) == nil else { return parsed }
        let match = options.first { $0.value.display == raw || $0.label.text.caseInsensitiveCompare(raw) == .orderedSame }
            ?? options.first { $0.label.values.values.contains { $0.caseInsensitiveCompare(raw) == .orderedSame } }
        return match?.value ?? parsed
    }
}
