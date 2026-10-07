import AppKit
import AVFoundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Renders a wallpaper without a window: posters, previews, CLI renders and benchmarks.
@MainActor
final class OffscreenRenderer {
    let session: SceneSession
    let size: CGSize
    private let encoder: SceneEncoder
    private let target: MTLTexture
    private let consumer = NSObject()

    init(wallpaper: Wallpaper, values: [String: JSONValue], size: CGSize) {
        session = SceneSession(wallpaper: wallpaper, values: values)
        self.size = size
        encoder = SceneEncoder(session: session)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPU.shared.pixelFormat, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        target = GPU.shared.device.makeTexture(descriptor: d)!
    }

    /// Waits (pumping the run loop) until textures, shaders and video frames are loaded.
    func waitUntilReady(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !session.isReady, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return session.isReady
    }

    /// The async variant for callers already running on the main actor, where pumping the run loop
    /// can't execute the loading tasks it waits for.
    func ready(timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !session.isReady, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return session.isReady
    }

    func setPlaying(_ playing: Bool) {
        session.setPlaying(playing, consumer: consumer)
    }

    struct Timing { var cpuMs: Double; var gpuMs: Double }

    @discardableResult
    func render(time: Double? = nil, dt: Double = 1.0 / 30, settings: RenderSettings = RenderSettings()) -> Timing {
        if let time { seek(time) }
        let cb = GPU.shared.queue.makeCommandBuffer()!
        let start = CACurrentMediaTime()
        encoder.encode(cb, output: target, input: FrameInput(
            hostTime: CACurrentMediaTime(),
            dt: dt,
            outputSize: size,
            renderScale: settings.renderScale,
            focus: settings.focus ?? session.wallpaper.manifest.focus,
            parallax: .zero,
            parallaxStrength: settings.parallaxStrength,
            pointer: nil,
            grade: settings.grade,
            daylight: Ambient.daylight(),
            dark: Ambient.isDark ? 1 : 0
        ))
        let cpu = (CACurrentMediaTime() - start) * 1000
        cb.commit()
        cb.waitUntilCompleted()
        return Timing(cpuMs: cpu, gpuMs: (cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }

    /// Moves the clock and every clip to `seconds`, waiting briefly for seeked video frames to decode.
    private func seek(_ seconds: Double) {
        let now = session.time(at: CACurrentMediaTime())
        guard abs(now - seconds) > 1e-6 else { return }
        session.setTime(seconds)
        if session.scene.layers.contains(where: { $0.video != nil }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
    }

    func image() -> CGImage? {
        let w = target.width, h = target.height
        let bytesPerRow = w * 4
        guard let buffer = GPU.shared.device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared),
              let cb = GPU.shared.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * h)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let retained = Unmanaged.passRetained(buffer as AnyObject).toOpaque()
        guard let provider = CGDataProvider(dataInfo: retained, data: buffer.contents(), size: bytesPerRow * h, releaseData: { info, _, _ in
            if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
        }) else {
            Unmanaged<AnyObject>.fromOpaque(retained).release()
            return nil
        }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func tearDown() {
        session.setPlaying(false, consumer: consumer)
        session.tearDown()
    }

    nonisolated static func write(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        let type: UTType = switch url.pathExtension.lowercased() {
        case "heic": .heic
        case "jpg", "jpeg": .jpeg
        default: .png
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

enum PosterMaker {
    /// Frame 0 at canvas size (capped at 6K on the long side), written as HEIC into the package.
    @MainActor
    static func make(for wallpaper: Wallpaper, values: [String: JSONValue] = [:], to destination: URL? = nil) async throws -> URL {
        let canvas = wallpaper.manifest.canvas
        let scale = min(1, 6144 / max(canvas.width, canvas.height))
        let size = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
        let r = OffscreenRenderer(wallpaper: wallpaper, values: values, size: size)
        defer { r.tearDown() }
        _ = await r.ready()
        r.render(time: 0, dt: 0)
        guard let image = r.image() else { throw CocoaError(.fileWriteUnknown) }
        guard let url = destination ?? wallpaper.file(wallpaper.manifest.poster ?? "poster.heic") else {
            throw ManifestError(path: "poster", message: "must stay inside the package")
        }
        try await Task.detached(priority: .utility) {
            try OffscreenRenderer.write(image, to: url, quality: 0.92)
        }.value
        return url
    }
}
