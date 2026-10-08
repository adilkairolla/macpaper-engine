import Foundation

/// Where one display sits in a picture spread across several: the arrangement's whole size in points, and this
/// display's part of it (0…1, top-left origin).
struct Span: Hashable, Sendable {
    var total: CGSize
    var rect: CGRect
}

/// How one display shows one wallpaper. Everything here belongs to the app, never to the package.
struct RenderSettings: Equatable {
    var focus: SIMD2<Double>?
    var showAll = false
    var speed: Double = 1
    var fpsCap: Int = 0
    var grade = GradeUniforms()
    var parallaxStrength: Double = 1
    var pointerParallax = true
    var renderScale: Double = 1
    var volume: Double = 0.6
    var muted = true
    var allowVideoFastPath = true
    var maxFPS: Int = 120
    var span: Span?
    var reactions = true
    var restMode = RestMode.cycle

    static func == (a: RenderSettings, b: RenderSettings) -> Bool {
        a.focus == b.focus && a.showAll == b.showAll && a.speed == b.speed && a.fpsCap == b.fpsCap && a.grade == b.grade
            && a.parallaxStrength == b.parallaxStrength && a.pointerParallax == b.pointerParallax
            && a.renderScale == b.renderScale && a.volume == b.volume && a.muted == b.muted
            && a.allowVideoFastPath == b.allowVideoFastPath && a.maxFPS == b.maxFPS && a.span == b.span && a.reactions == b.reactions
            && a.restMode == b.restMode
    }
}

extension GradeUniforms: Equatable {
    static func == (a: GradeUniforms, b: GradeUniforms) -> Bool {
        a.brightness == b.brightness && a.contrast == b.contrast && a.saturation == b.saturation && a.warmth == b.warmth
    }
}

struct FrameStats: Equatable {
    var fps: Double = 0
    var cpuMs: Double = 0
    var gpuMs: Double = 0
    var path = "—"

    var summary: String {
        path == "Direct video"
            ? String(format: "Hardware video playback · %.0f fps", fps)
            : String(format: "Rendered · %.0f fps · %.1f ms GPU", fps, gpuMs)
    }
}

enum Ambient {
    /// 0 at night, 1 by day, with an hour-long dawn and dusk around 7:00 and 19:00.
    static func daylight(_ date: Date = Date()) -> Float {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        return Float(smooth(6.5, 7.5, h) - smooth(18.5, 19.5, h))
    }

    static var isDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
