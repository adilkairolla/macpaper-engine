import Foundation
import Metal

struct ShaderDiagnostic: Hashable, Sendable {
    var file: String
    var line: Int
    var column: Int
    var severity: String
    var message: String

    var description: String {
        line > 0 ? "\(file):\(line):\(column): \(severity): \(message)" : "\(file): \(severity): \(message)"
    }
}

struct ShaderCompileError: Error, CustomStringConvertible {
    var diagnostics: [ShaderDiagnostic]
    var description: String { diagnostics.map(\.description).joined(separator: "\n") }
}

/// Packs shader params into the byte layout of the generated MSL `Params` struct.
struct ParamLayout {
    struct Field { var param: ShaderParam; var offset: Int }
    let fields: [Field]
    let size: Int

    init(_ params: [ShaderParam]) {
        var offset = 0
        var maxAlign = 4
        var fields: [Field] = []
        for p in params {
            let (size, align) = Self.sizeAlign(p.type)
            offset = (offset + align - 1) / align * align
            fields.append(Field(param: p, offset: offset))
            offset += size
            maxAlign = max(maxAlign, align)
        }
        self.fields = fields
        size = max(4, (offset + maxAlign - 1) / maxAlign * maxAlign)
    }

    static func sizeAlign(_ t: ParamType) -> (Int, Int) {
        switch t {
        case .float, .int, .bool: (4, 4)
        case .float2: (8, 8)
        case .float3, .float4, .color: (16, 16)
        }
    }

    func pack(_ params: [ShaderParam]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        let byName = Dictionary(params.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for f in fields {
            let value = byName[f.param.name]?.value ?? f.param.value
            let floats: [Float]
            switch f.param.type {
            case .float: floats = [Float(value.number ?? value.bool.map { $0 ? 1 : 0 } ?? 0)]
            case .float2, .float3, .float4:
                let n = f.param.type == .float2 ? 2 : f.param.type == .float3 ? 3 : 4
                let v = value.numbers ?? [value.number ?? 0]
                floats = (0..<n).map { i in Float(i < v.count ? v[i] : (v.count == 1 ? v[0] : 0)) }
            case .color:
                let c = RGBA(value) ?? .white
                floats = [Float(c.r), Float(c.g), Float(c.b), Float(c.a)]
            case .int, .bool:
                var i = Int32(value.int(in: Int(Int32.min)...Int(Int32.max)) ?? 0)
                if let b = value.bool { i = b ? 1 : 0 }
                withUnsafeBytes(of: &i) { raw in
                    for (k, byte) in raw.enumerated() { bytes[f.offset + k] = byte }
                }
                continue
            }
            for (k, var fl) in floats.enumerated() {
                withUnsafeBytes(of: &fl) { raw in
                    for (b, byte) in raw.enumerated() { bytes[f.offset + k * 4 + b] = byte }
                }
            }
        }
        return bytes
    }
}

/// A user shader wrapped in the generated contract and compiled to a fragment function.
final class ShaderProgram: @unchecked Sendable {
    let function: MTLFunction
    let layout: ParamLayout
    let textureNames: [String]
    let readsSource: Bool
    /// Pipelines live with their program, so a recompiled shader can never pick up a stale one.
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var packed: (params: [ShaderParam], bytes: [UInt8])?

    static let reservedNames: Set<String> = ["source", "linear", "repeat", "nearest"]

    private init(function: MTLFunction, spec: ShaderSpec, readsSource: Bool) {
        self.function = function
        layout = ParamLayout(spec.params)
        textureNames = spec.textures.map(\.name)
        self.readsSource = readsSource
    }

    @MainActor
    func pipeline(blend: Blend?) -> MTLRenderPipelineState? {
        let key = blend?.rawValue ?? "opaque"
        if let p = pipelines[key] { return p }
        let p = try? GPU.shared.makePipeline(fragment: function, blend: blend)
        pipelines[key] = p
        return p
    }

    /// Param values only change when the user moves a control, so the packed bytes are reused between frames.
    @MainActor
    func pack(_ params: [ShaderParam]) -> [UInt8] {
        if let packed, packed.params == params { return packed.bytes }
        let bytes = layout.pack(params)
        packed = (params, bytes)
        return bytes
    }

    @MainActor private static var compiled: [String: Task<ShaderProgram, Error>] = [:]
    @MainActor private static var compiledOrder: [String] = []

    /// One compile per distinct shader for the whole app: the validator and every session share it.
    @MainActor
    static func shared(spec: ShaderSpec, source: String, fileName: String, device: MTLDevice) async throws -> ShaderProgram {
        let key = cacheKey(spec, source: source)
        if let task = compiled[key] { return try await task.value }
        let task = Task { try await compile(spec: spec, source: source, fileName: fileName, device: device) }
        compiled[key] = task
        compiledOrder.append(key)
        if compiledOrder.count > 48 { compiled[compiledOrder.removeFirst()] = nil }
        return try await task.value
    }

    static func compile(spec: ShaderSpec, source: String, fileName: String, device: MTLDevice) async throws -> ShaderProgram {
        guard spec.function.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw ShaderCompileError(diagnostics: [ShaderDiagnostic(file: fileName, line: 0, column: 0, severity: "error", message: "`function` must be a plain MSL function name")])
        }
        let full = generate(spec: spec, user: source, fileName: fileName)
        let library: MTLLibrary
        do {
            library = try await device.makeLibrary(source: full, options: GPU.compileOptions)
        } catch {
            throw ShaderCompileError(diagnostics: parse(error, fileName: fileName))
        }
        guard let f = library.makeFunction(name: "mp_user_entry") else {
            throw ShaderCompileError(diagnostics: [ShaderDiagnostic(file: fileName, line: 0, column: 0, severity: "error", message: "no `\(spec.function)` function found")])
        }
        let reads = source.range(of: #"\.\s*source\b"#, options: .regularExpression) != nil
        return ShaderProgram(function: f, spec: spec, readsSource: reads)
    }

    /// Params with the same names and types share a compiled program; only their values differ.
    static func cacheKey(_ spec: ShaderSpec, source: String) -> String {
        var h = Hasher()
        h.combine(source)
        h.combine(spec.function)
        for p in spec.params { h.combine(p.name); h.combine(p.type) }
        for t in spec.textures { h.combine(t.name) }
        return "\(spec.src)#\(h.finalize())"
    }

    static func generate(spec: ShaderSpec, user: String, fileName: String) -> String {
        var s = ShaderSource.common
        s += "\nstruct Params {\n"
        if spec.params.isEmpty { s += "    float _unused;\n" }
        for p in spec.params { s += "    \(p.type.mslType) \(p.name);\n" }
        s += "};\n\nstruct Inputs {\n    texture2d<float> source;\n"
        for t in spec.textures { s += "    texture2d<float> \(t.name);\n" }
        s += "    sampler linear;\n    sampler repeat;\n    sampler nearest;\n};\n\n"
        s += "struct Pixel {\n    float2 uv;\n    float2 screen;\n    float2 coord;\n};\n\n"
        s += "#line 1 \"\(fileName)\"\n"
        s += user
        s += "\n#line 1 \"macpaper-generated\"\n"
        s += "fragment float4 mp_user_entry(MPVertexOut v [[stage_in]], constant Frame& frame [[buffer(0)]], constant Params& params [[buffer(1)]], constant MPLayer& layer [[buffer(2)]], texture2d<float> source [[texture(0)]]"
        for (i, t) in spec.textures.enumerated() { s += ", texture2d<float> mp_t_\(t.name) [[texture(\(i + 1))]]" }
        s += ") {\n"
        s += "    constexpr sampler mp_linear(filter::linear, mip_filter::linear, address::clamp_to_edge);\n"
        s += "    constexpr sampler mp_repeat(filter::linear, mip_filter::linear, address::repeat);\n"
        s += "    constexpr sampler mp_nearest(filter::nearest, address::clamp_to_edge);\n"
        s += "    Inputs in = { source"
        for t in spec.textures { s += ", mp_t_\(t.name)" }
        s += ", mp_linear, mp_repeat, mp_nearest };\n"
        s += "    Pixel px = { mp_layer_uv(v.uv, layer), v.screen, v.position.xy };\n"
        s += "    return mp_finish(\(spec.function)(px, frame, params, in), layer, source, v.screen);\n}\n"
        return s
    }

    static func parse(_ error: Error, fileName: String) -> [ShaderDiagnostic] {
        let text = (error as NSError).localizedDescription
        var out: [ShaderDiagnostic] = []
        let pattern = #"^([^\n:]+):(\d+):(\d+): (error|warning): (.*)$"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func g(_ i: Int) -> String { String(text[Range(m.range(at: i), in: text)!]) }
            let file = g(1)
            guard g(4) == "error" else { continue }
            out.append(ShaderDiagnostic(
                file: file == "macpaper-generated" ? fileName : file,
                line: file == "macpaper-generated" ? 0 : Int(g(2)) ?? 0,
                column: Int(g(3)) ?? 0,
                severity: g(4),
                message: file == "macpaper-generated" ? "the `effect` function doesn't match the contract: " + g(5) : g(5)
            ))
        }
        if out.isEmpty {
            out.append(ShaderDiagnostic(file: fileName, line: 0, column: 0, severity: "error", message: text))
        }
        return out
    }
}
