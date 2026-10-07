import Foundation

enum ParticlePresets {
    static let base: [String: JSONValue] = [
        "count": 200,
        "area": JSONValue([0, 0, 1, 1]),
        "lifetime": JSONValue([4, 8]),
        "speed": JSONValue([0.02, 0.05]),
        "direction": 90,
        "spread": 30,
        "gravity": JSONValue([0, 0]),
        "wind": JSONValue([0, 0]),
        "turbulence": 0,
        "turbulenceScale": 2,
        "size": JSONValue([0.002, 0.005]),
        "color": "#ffffff",
        "fade": JSONValue([0.1, 0.2]),
        "twinkle": 0,
        "shape": "dot",
        "spin": JSONValue([0, 0]),
        "stretch": 0.04,
        "mouse": 0,
    ]

    static let presets: [String: [String: JSONValue]] = [
        "snow": [
            "count": 700, "area": JSONValue([-0.1, -0.08, 1.2, 0.05]), "lifetime": JSONValue([10, 18]),
            "speed": JSONValue([0.04, 0.09]), "direction": 90, "spread": 25, "wind": JSONValue([0.01, 0]),
            "turbulence": 0.03, "turbulenceScale": 3, "size": JSONValue([0.0015, 0.005]),
            "color": "#ffffffee", "fade": JSONValue([0.05, 0.15]), "shape": "dot", "mouse": 0.15,
        ],
        "rain": [
            "count": 1400, "area": JSONValue([-0.2, -0.12, 1.4, 0.06]), "lifetime": JSONValue([0.8, 1.4]),
            "speed": JSONValue([1.2, 1.8]), "direction": 100, "spread": 3, "size": JSONValue([0.0007, 0.0013]),
            "color": "#c8d8ff80", "fade": JSONValue([0, 0.05]), "shape": "streak", "stretch": 0.04,
        ],
        "fireflies": [
            "count": 80, "area": JSONValue([0, 0.3, 1, 0.7]), "lifetime": JSONValue([4, 9]),
            "speed": JSONValue([0.005, 0.02]), "direction": -90, "spread": 180, "turbulence": 0.04,
            "turbulenceScale": 2, "size": JSONValue([0.003, 0.008]), "color": "#ffdd77", "colorEnd": "#ffaa33",
            "fade": JSONValue([0.3, 0.4]), "twinkle": 0.8, "shape": "glow", "blend": "add", "mouse": -0.1,
        ],
        "dust": [
            "count": 300, "lifetime": JSONValue([6, 14]), "speed": JSONValue([0.002, 0.01]), "direction": 0,
            "spread": 180, "turbulence": 0.01, "size": JSONValue([0.0008, 0.002]), "color": "#fff4e099",
            "fade": JSONValue([0.3, 0.3]), "twinkle": 0.3, "shape": "dot", "blend": "add",
        ],
        "embers": [
            "count": 200, "area": JSONValue([0, 0.95, 1, 0.1]), "lifetime": JSONValue([3, 7]),
            "speed": JSONValue([0.06, 0.15]), "direction": -90, "spread": 25, "turbulence": 0.06,
            "turbulenceScale": 4, "size": JSONValue([0.001, 0.003]), "color": "#ffb347", "colorEnd": "#ff3b1f",
            "fade": JSONValue([0.05, 0.5]), "twinkle": 0.5, "shape": "glow", "blend": "add",
        ],
        "bokeh": [
            "count": 40, "lifetime": JSONValue([8, 16]), "speed": JSONValue([0.003, 0.01]), "direction": -90,
            "spread": 180, "size": JSONValue([0.02, 0.06]), "color": "#ffffff40", "fade": JSONValue([0.4, 0.4]),
            "shape": "dot", "blend": "add",
        ],
        "stars": [
            "count": 400, "area": JSONValue([0, 0, 1, 0.6]), "lifetime": JSONValue([6, 12]),
            "speed": JSONValue([0, 0]), "size": JSONValue([0.0006, 0.0018]), "fade": JSONValue([0.2, 0.2]),
            "twinkle": 1, "shape": "glow", "blend": "add",
        ],
        "bubbles": [
            "count": 120, "area": JSONValue([0, 1.0, 1, 0.05]), "lifetime": JSONValue([6, 12]),
            "speed": JSONValue([0.03, 0.08]), "direction": -90, "spread": 10, "turbulence": 0.02,
            "size": JSONValue([0.003, 0.01]), "color": "#ffffff99", "shape": "ring", "blend": "add", "mouse": 0.2,
        ],
        "petals": [
            "count": 90, "area": JSONValue([-0.1, -0.1, 1.2, 0.05]), "lifetime": JSONValue([8, 14]),
            "speed": JSONValue([0.03, 0.07]), "direction": 75, "spread": 30, "wind": JSONValue([0.02, 0]),
            "turbulence": 0.05, "size": JSONValue([0.006, 0.012]), "color": "#ffc0d0", "colorEnd": "#ffd8e0",
            "spin": JSONValue([-2, 2]), "shape": "petal", "mouse": 0.2,
        ],
    ]

    static var names: [String] { presets.keys.sorted() }

    /// Base defaults, then the preset, then the layer's own fields.
    static func merged(_ layer: [String: JSONValue]) -> [String: JSONValue] {
        var out = base
        if let name = layer["preset"]?.string, let preset = presets[name] {
            out.merge(preset) { _, new in new }
        }
        out.merge(layer) { _, new in new }
        return out
    }
}
