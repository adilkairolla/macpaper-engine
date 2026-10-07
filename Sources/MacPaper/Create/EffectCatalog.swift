import Foundation

/// Built-in effects the Create page can add. Shader effects ship as `.metal` files in the app bundle and
/// are copied into the package, so packages never depend on the app version that made them.
struct EffectDefinition: Identifiable, Hashable {
    enum Source: Hashable {
        case shader(String)
        case particles(String)
    }

    struct Knob: Hashable {
        enum Kind: Hashable {
            case slider(min: Double, max: Double, unit: String?)
            case color
            case point
        }
        var property: String
        var label: String
        var kind: Kind
    }

    let id: String
    let name: String
    let symbol: String
    let summary: String
    let source: Source
    var params: [ShaderParam] = []
    var usesMask = false
    var maskHint = ""
    var blend: Blend = .normal
    var knobs: [Knob] = []

    static func slider(_ property: String, _ label: String, _ min: Double, _ max: Double, unit: String? = nil) -> Knob {
        Knob(property: property, label: label, kind: .slider(min: min, max: max, unit: unit))
    }

    static func color(_ property: String, _ label: String) -> Knob { Knob(property: property, label: label, kind: .color) }
    static func point(_ property: String, _ label: String) -> Knob { Knob(property: property, label: label, kind: .point) }

    static func p(_ name: String, _ type: ParamType, _ value: JSONValue) -> ShaderParam {
        ShaderParam(name: name, type: type, value: value)
    }

    var isShader: Bool { if case .shader = source { true } else { false } }
}

enum EffectCatalog {
    static let all: [EffectDefinition] = shaders + particles

    private static func p(_ name: String, _ type: ParamType, _ value: JSONValue) -> ShaderParam { EffectDefinition.p(name, type, value) }
    private static func slider(_ property: String, _ label: String, _ min: Double, _ max: Double, unit: String? = nil) -> EffectDefinition.Knob {
        EffectDefinition.slider(property, label, min, max, unit: unit)
    }
    private static func color(_ property: String, _ label: String) -> EffectDefinition.Knob { EffectDefinition.color(property, label) }
    private static func point(_ property: String, _ label: String) -> EffectDefinition.Knob { EffectDefinition.point(property, label) }

    static let shaders: [EffectDefinition] = [
        EffectDefinition(
            id: "rain-glass", name: "Rain on Glass", symbol: "cloud.rain", summary: "Drops run down a misted window over the scene.",
            source: .shader("rain-glass.metal"),
            params: [p("amount", .float, 0.75), p("speed", .float, 1), p("size", .float, 1), p("blur", .float, 0.8)],
            knobs: [slider("amount", "Rain", 0, 1, unit: "%"), slider("speed", "Speed", 0.1, 3, unit: "x"), slider("size", "Drop size", 0.5, 2), slider("blur", "Mist", 0, 3)]
        ),
        EffectDefinition(
            id: "water", name: "Water", symbol: "water.waves", summary: "Ripples and glints on water.",
            source: .shader("water.metal"),
            params: [p("strength", .float, 1), p("speed", .float, 1), p("scale", .float, 5), p("glints", .float, 0.6)],
            usesMask: true, maskHint: "Paint the water.",
            knobs: [slider("strength", "Ripples", 0, 3), slider("speed", "Speed", 0, 3, unit: "x"), slider("scale", "Scale", 1, 20), slider("glints", "Glints", 0, 1, unit: "%")]
        ),
        EffectDefinition(
            id: "light-rays", name: "Light Rays", symbol: "sun.max", summary: "Volumetric light streaming from a point.",
            source: .shader("light-rays.metal"),
            params: [p("origin", .float2, JSONValue([0.5, 0.2])), p("intensity", .float, 0.35), p("length", .float, 0.5), p("threshold", .float, 0.7), p("color", .color, "#ffe2b0")],
            knobs: [point("origin", "Light source"), slider("intensity", "Intensity", 0, 2), slider("length", "Length", 0.1, 1), slider("threshold", "Threshold", 0, 1), color("color", "Color")]
        ),
        EffectDefinition(
            id: "heat-haze", name: "Heat Haze", symbol: "thermometer.sun", summary: "Shimmering air over hot ground or flames.",
            source: .shader("heat-haze.metal"),
            params: [p("strength", .float, 1), p("speed", .float, 1)],
            usesMask: true, maskHint: "Paint where the air shimmers.",
            knobs: [slider("strength", "Strength", 0, 3), slider("speed", "Speed", 0, 3, unit: "x")]
        ),
        EffectDefinition(
            id: "fog", name: "Fog", symbol: "cloud.fog", summary: "Low rolling fog.",
            source: .shader("fog.metal"),
            params: [p("density", .float, 0.6), p("height", .float, 0.7), p("speed", .float, 1), p("color", .color, "#d8dde6")],
            knobs: [slider("density", "Density", 0, 1, unit: "%"), slider("height", "Height", 0, 1), slider("speed", "Speed", 0, 4, unit: "x"), color("color", "Color")]
        ),
        EffectDefinition(
            id: "clouds", name: "Drifting Clouds", symbol: "cloud", summary: "Clouds passing across the sky.",
            source: .shader("clouds.metal"),
            params: [p("coverage", .float, 0.45), p("softness", .float, 0.35), p("speed", .float, 1), p("scale", .float, 1.5), p("opacity", .float, 0.8), p("color", .color, "#ffffff")],
            usesMask: true, maskHint: "Paint the sky.",
            knobs: [slider("coverage", "Coverage", 0, 1, unit: "%"), slider("softness", "Softness", 0.05, 1), slider("speed", "Speed", 0, 5, unit: "x"), slider("scale", "Scale", 0.3, 4), slider("opacity", "Opacity", 0, 1, unit: "%"), color("color", "Color")]
        ),
        EffectDefinition(
            id: "aurora", name: "Aurora", symbol: "sparkles", summary: "Northern lights rippling over the sky.",
            source: .shader("aurora.metal"),
            params: [p("intensity", .float, 0.9), p("height", .float, 0.25), p("speed", .float, 1), p("colorA", .color, "#3dffb0"), p("colorB", .color, "#8a5cff")],
            blend: .screen,
            knobs: [slider("intensity", "Intensity", 0, 2), slider("height", "Height", 0, 0.8), slider("speed", "Speed", 0, 4, unit: "x"), color("colorA", "Lower color"), color("colorB", "Upper color")]
        ),
        EffectDefinition(
            id: "lightning", name: "Lightning", symbol: "cloud.bolt", summary: "Distant storm flashes in the sky.",
            source: .shader("lightning.metal"),
            params: [p("frequency", .float, 1), p("intensity", .float, 0.8), p("color", .color, "#dfe6ff")],
            usesMask: true, maskHint: "Paint the sky.", blend: .add,
            knobs: [slider("frequency", "Frequency", 0.1, 5), slider("intensity", "Intensity", 0, 2), color("color", "Color")]
        ),
        EffectDefinition(
            id: "bloom", name: "Bloom", symbol: "light.max", summary: "Soft glow around highlights.",
            source: .shader("bloom.metal"),
            params: [p("threshold", .float, 0.7), p("intensity", .float, 0.5), p("radius", .float, 1.5)],
            knobs: [slider("threshold", "Threshold", 0, 1), slider("intensity", "Intensity", 0, 2), slider("radius", "Radius", 0.2, 4)]
        ),
        EffectDefinition(
            id: "day-night", name: "Day & Night", symbol: "sun.horizon", summary: "Cool at night, warm at dawn and dusk — follows your clock.",
            source: .shader("day-night.metal"),
            params: [p("strength", .float, 0.8)],
            knobs: [slider("strength", "Strength", 0, 1, unit: "%")]
        ),
        EffectDefinition(
            id: "audio-glow", name: "Music Pulse", symbol: "waveform", summary: "Highlights pulse with the bass. Needs Audio-reactive on.",
            source: .shader("audio-glow.metal"),
            params: [p("intensity", .float, 0.8), p("color", .color, "#ff7ad9")],
            knobs: [slider("intensity", "Intensity", 0, 2), color("color", "Color")]
        ),
        EffectDefinition(
            id: "vignette", name: "Vignette", symbol: "circle.dashed", summary: "Darkened edges.",
            source: .shader("vignette.metal"),
            params: [p("amount", .float, 0.6), p("radius", .float, 0.9), p("softness", .float, 0.6), p("color", .color, "#000000")],
            knobs: [slider("amount", "Amount", 0, 1, unit: "%"), slider("radius", "Radius", 0.3, 1.5), slider("softness", "Softness", 0.05, 1)]
        ),
        EffectDefinition(
            id: "film-grain", name: "Film Grain", symbol: "camera.filters", summary: "Fine animated grain.",
            source: .shader("film-grain.metal"),
            params: [p("amount", .float, 0.3), p("size", .float, 1.5)],
            knobs: [slider("amount", "Amount", 0, 1, unit: "%"), slider("size", "Grain size", 1, 4)]
        ),
    ]

    static let particles: [EffectDefinition] = [
        particle("snow", "Snow", "snowflake", "Soft snow drifting down."),
        particle("rain", "Rain", "cloud.heavyrain", "Falling rain streaks."),
        particle("fireflies", "Fireflies", "sparkle", "Glowing fireflies wandering about.", mask: "Paint where fireflies appear."),
        particle("dust", "Dust Motes", "aqi.low", "Specks floating in the light."),
        particle("embers", "Embers", "flame", "Sparks rising from below."),
        particle("bokeh", "Bokeh", "circle.hexagongrid", "Large out-of-focus lights."),
        particle("stars", "Twinkling Stars", "star", "Stars twinkling in the sky.", mask: "Paint the sky."),
        particle("bubbles", "Bubbles", "bubbles.and.sparkles", "Bubbles rising."),
        particle("petals", "Petals", "leaf", "Blossom petals on the wind."),
    ]

    private static func particle(_ preset: String, _ name: String, _ symbol: String, _ summary: String, mask: String? = nil) -> EffectDefinition {
        let p = ParticlePresets.merged(["preset": .string(preset)])
        return EffectDefinition(
            id: preset, name: name, symbol: symbol, summary: summary, source: .particles(preset),
            usesMask: mask != nil, maskHint: mask ?? "",
            blend: Blend(rawValue: p["blend"]?.string ?? "") ?? .normal,
            knobs: [
                slider("count", "Amount", 0, max(200, (p["count"]?.number ?? 200) * 3)),
                slider("turbulence", "Swirl", 0, 0.2),
                color("color", "Color"),
            ]
        )
    }

    static func definition(_ id: String) -> EffectDefinition? { all.first { $0.id == id } }

    static func shaderSource(_ file: String) -> String? {
        let candidates = [
            Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Effects"),
            Bundle.main.resourceURL?.appendingPathComponent("Effects/\(file)"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Effects/\(file)").standardizedFileURL,
        ]
        for url in candidates.compactMap({ $0 }) {
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        }
        return nil
    }
}
