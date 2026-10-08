import AppKit
import ImageIO

/// Posters decoded, cropped and sized for a display ahead of time, so showing a wallpaper costs one memory copy.
@MainActor
final class PosterCache {
    static let shared = PosterCache()

    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let cache = NSCache<NSString, Box>()
    private var pending: [String: [(CGImage?) -> Void]] = [:]
    private var keysByWallpaper: [String: Set<String>] = [:]
    private let queue = DispatchQueue(label: "macpaper.posters", qos: .userInitiated, attributes: .concurrent)

    /// Room for a few posters per display; hovering across a large library must not pin hundreds of megabytes.
    init() {
        let displayBytes = NSScreen.screens.reduce(0) { sum, s in
            sum + Int(s.frame.width * s.backingScaleFactor * s.frame.height * s.backingScaleFactor * 4)
        }
        cache.totalCostLimit = max(96 << 20, displayBytes * 3)
    }

    private func key(_ w: Wallpaper, _ size: CGSize, _ focus: SIMD2<Double>, _ span: Span?) -> String {
        "\(w.id)@\(w.stamp.timeIntervalSince1970)|\(Int(size.width))x\(Int(size.height))|\(focus.x),\(focus.y)|\(span.map { "\($0.total)\($0.rect)" } ?? "")"
    }

    func cached(_ wallpaper: Wallpaper, size: CGSize, focus: SIMD2<Double>, span: Span? = nil) -> CGImage? {
        cache.object(forKey: key(wallpaper, size, focus, span) as NSString)?.image
    }

    func image(_ wallpaper: Wallpaper, size: CGSize, focus: SIMD2<Double>, span: Span? = nil, completion: @escaping (CGImage?) -> Void) {
        let k = key(wallpaper, size, focus, span)
        if let hit = cache.object(forKey: k as NSString) {
            completion(hit.image)
            return
        }
        if pending[k] != nil {
            pending[k]!.append(completion)
            return
        }
        pending[k] = [completion]
        guard let url = wallpaper.effectivePosterURL else {
            finish(k, nil)
            return
        }
        queue.async {
            let image = Self.decode(url, size: size, focus: focus, span: span)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(k, image) }
            }
        }
    }

    func invalidate(_ wallpaperID: String) {
        for k in keysByWallpaper.removeValue(forKey: wallpaperID) ?? [] {
            cache.removeObject(forKey: k as NSString)
        }
    }

    private func finish(_ key: String, _ image: CGImage?) {
        if let image {
            cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
            if let id = key.split(separator: "@").first { keysByWallpaper[String(id), default: []].insert(key) }
        }
        let waiters = pending.removeValue(forKey: key) ?? []
        waiters.forEach { $0(image) }
    }

    func prewarm(_ wallpaper: Wallpaper, sizes: [CGSize], focus: (CGSize) -> SIMD2<Double>) {
        for s in sizes { image(wallpaper, size: s, focus: focus(s)) { _ in } }
    }

    nonisolated static func decode(_ url: URL, size: CGSize, focus: SIMD2<Double>, span: Span? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let region = SceneEncoder.region(canvas: CGSize(width: pw, height: ph), output: size, focus: focus, span: span)
        let need = max(size.width / (Double(region.z) * Double(pw)), size.height / (Double(region.w) * Double(ph)))
        let maxSide = Int((Double(max(pw, ph)) * min(need, 1)).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxSide, 16),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let fw = Double(full.width), fh = Double(full.height)
        let crop = CGRect(x: Double(region.x) * fw, y: Double(region.y) * fh, width: Double(region.z) * fw, height: Double(region.w) * fh).integral
        return full.cropping(to: crop) ?? full
    }
}
