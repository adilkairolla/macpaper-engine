import Foundation
import simd

/// Text that may be given once or per language: `"Title"` or `{"en": "Title", "ru": "Название"}`.
struct Localized: Hashable, Sendable {
    var values: [String: String]

    init(_ text: String) { values = ["": text] }

    init?(_ json: JSONValue?) {
        switch json {
        case .string(let s): values = ["": s]
        case .object(let o):
            let strings = o.compactMapValues(\.string)
            guard !strings.isEmpty else { return nil }
            values = strings
        default: return nil
        }
    }

    var text: String {
        if let plain = values[""] { return plain }
        for lang in Locale.preferredLanguages {
            let code = String(lang.prefix(2))
            if let v = values[lang] ?? values[code] { return v }
        }
        return values["en"] ?? values.values.sorted().first ?? ""
    }
}

struct RGBA: Hashable, Sendable {
    var r, g, b, a: Double

    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init?(_ json: JSONValue?) {
        if let s = json?.string {
            var hex = s.trimmingCharacters(in: .whitespaces)
            if hex.hasPrefix("#") { hex.removeFirst() }
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                self.init(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255)
            } else {
                self.init(r: Double((v >> 24) & 255) / 255, g: Double((v >> 16) & 255) / 255, b: Double((v >> 8) & 255) / 255, a: Double(v & 255) / 255)
            }
        } else if let n = json?.numbers, n.count == 3 || n.count == 4 {
            self.init(r: n[0], g: n[1], b: n[2], a: n.count == 4 ? n[3] : 1)
        } else {
            return nil
        }
    }

    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), Float(a)) }

    var hex: String {
        func c(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b) + (a < 0.999 ? c(a) : "")
    }

    var json: JSONValue { .string(hex) }
}

struct NormRect: Hashable, Sendable {
    var x, y, w, h: Double
    static let full = NormRect(x: 0, y: 0, w: 1, h: 1)

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    init?(_ json: JSONValue?) {
        guard let n = json?.numbers, n.count == 4 else { return nil }
        self.init(x: n[0], y: n[1], w: n[2], h: n[3])
    }

    var simd: SIMD4<Float> { SIMD4(Float(x), Float(y), Float(w), Float(h)) }
}

struct Range2: Hashable, Sendable {
    var lo, hi: Double

    init(_ lo: Double, _ hi: Double) { self.lo = lo; self.hi = hi }

    init?(_ json: JSONValue?) {
        if let n = json?.number { self.init(n, n); return }
        guard let n = json?.numbers, n.count == 2 else { return nil }
        self.init(n[0], n[1])
    }

    var simd: SIMD2<Float> { SIMD2(Float(lo), Float(hi)) }
}

extension SIMD2 where Scalar == Double {
    init?(_ json: JSONValue?) {
        guard let n = json?.numbers, n.count == 2 else { return nil }
        self.init(n[0], n[1])
    }
    var float: SIMD2<Float> { SIMD2<Float>(Float(x), Float(y)) }
}
