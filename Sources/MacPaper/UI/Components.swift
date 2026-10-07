import AppKit
import ImageIO
import SwiftUI

/// Downsampled thumbnails, decoded off the main thread and cached.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, CGImageBox>()
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    init() { cache.countLimit = 400 }

    func image(for url: URL, maxSide: Int, stamp: Date = .distantPast) async -> CGImage? {
        let key = "\(url.path)|\(maxSide)|\(stamp.timeIntervalSince1970)"
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        if let task = inflight[key] { return await task.value }
        let task = Task<CGImage?, Never>.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { cache.setObject(CGImageBox(image), forKey: key as NSString) }
        return image
    }
}

struct Thumbnail: View {
    let url: URL?
    var stamp: Date = .distantPast
    var maxSide = 720
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            }
            .clipped()
        .task(id: "\(url?.path ?? "")|\(stamp)") {
            guard let url else { image = nil; return }
            let loaded = await ThumbnailLoader.shared.image(for: url, maxSide: maxSide, stamp: stamp)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

struct PosterThumbnail: View {
    let wallpaper: Wallpaper
    var maxSide = 720

    var body: some View {
        Thumbnail(url: wallpaper.posterURL, stamp: wallpaper.posterStamp, maxSide: maxSide)
    }
}

struct KindBadge: View {
    let kind: Wallpaper.Kind
    var body: some View {
        Label(kind.title, systemImage: kind.symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .foregroundStyle(.white)
            .background(.black.opacity(0.45), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 {
                x = 0
                y += row + spacing
                row = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            row = max(row, s.height)
        }
        return CGSize(width: maxX, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

/// Hosts a live WallpaperView, e.g. the inspector preview. Shares the session with the desktop.
struct LiveWallpaperPreview: NSViewRepresentable {
    let wallpaper: Wallpaper
    let values: [String: JSONValue]
    let settings: RenderSettings
    var paused = false

    final class Coordinator {
        var view: WallpaperView?
        deinit {
            let v = view
            DispatchQueue.main.async { MainActor.assumeIsolated { v?.tearDown() } }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        attach(to: host, context: context)
        return host
    }

    private func attach(to host: NSView, context: Context) {
        context.coordinator.view?.tearDown()
        context.coordinator.view?.removeFromSuperview()
        let session = SessionStore.shared.acquire(wallpaper, values: values)
        let view = WallpaperView(wallpaper: wallpaper, session: session, settings: settings, frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        view.pausesWithWindow = true
        host.addSubview(view)
        view.setPaused(paused)
        context.coordinator.view = view
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let view = context.coordinator.view else { return }
        if view.wallpaper != wallpaper {
            attach(to: host, context: context)
            return
        }
        view.update(settings: settings)
        view.setPaused(paused)
    }

    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) {
        coordinator.view?.tearDown()
        coordinator.view?.removeFromSuperview()
        coordinator.view = nil
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
