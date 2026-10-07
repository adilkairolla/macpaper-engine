import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

enum VideoQuality: String, CaseIterable, Identifiable {
    case original, uhd, hd
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original size"
        case .uhd: "4K"
        case .hd: "1080p"
        }
    }
    var preset: String {
        switch self {
        case .original: AVAssetExportPresetHEVCHighestQuality
        case .uhd: AVAssetExportPresetHEVC3840x2160
        case .hd: AVAssetExportPresetHEVC1920x1080
        }
    }
    var maxSide: CGFloat {
        switch self {
        case .original: .infinity
        case .uhd: 3840
        case .hd: 1920
        }
    }
}

struct MediaInfo {
    var size: CGSize
    var duration: Double
    var fps: Double
    var codec: FourCharCode?
    var playable: Bool
    var hasAudio: Bool

    var isEfficientCodec: Bool {
        guard let codec else { return false }
        return [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264, kCMVideoCodecType_HEVCWithAlpha].contains(codec)
    }
}

struct MediaError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum MediaTools {
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "webm") ?? .movie, UTType(filenameExtension: "mkv") ?? .movie]
    static let imageTypes: [UTType] = [.heic, .jpeg, .png, .webP, .tiff, .image]

    static func isVideo(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) || ["webm", "mkv"].contains(url.pathExtension.lowercased())
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Video

    static func info(_ url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo(size: .zero, duration: 0, fps: 30, codec: nil, playable: false, hasAudio: false)
        guard let playable = try? await asset.load(.isPlayable) else { return info }
        info.playable = playable
        info.duration = (try? await asset.load(.duration).seconds) ?? 0
        info.hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let (size, t, rate, descs) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions) {
                let r = CGRect(origin: .zero, size: size).applying(t)
                info.size = CGSize(width: abs(r.width), height: abs(r.height))
                info.fps = Double(rate > 0 ? rate : 30)
                info.codec = descs.first.map { CMFormatDescriptionGetMediaSubType($0) }
            }
        }
        return info
    }

    static func frame(_ url: URL, at seconds: Double = 0, maxSide: CGFloat? = nil) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        if let maxSide { gen.maximumSize = CGSize(width: maxSide, height: maxSide) }
        return try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Converts anything AVFoundation can't read (WebM, MKV…) to HEVC with ffmpeg and VideoToolbox.
    static func transcodeWithFFmpeg(_ url: URL, to out: URL) async throws {
        guard let ffmpeg else {
            throw MediaError(message: "\(url.lastPathComponent) needs converting and ffmpeg isn't installed. Install it with `brew install ffmpeg`, or convert the video to HEVC first.")
        }
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-y", "-v", "error", "-i", url.path, "-c:v", "hevc_videotoolbox", "-q:v", "70", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", out.path]
        let err = Pipe()
        p.standardError = err
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch { c.resume() }
            }
        } onCancel: {
            p.terminate()
        }
        try Task.checkCancellation()
        guard p.processIdentifier != 0 else { throw MediaError(message: "couldn't start ffmpeg") }
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MediaError(message: "ffmpeg couldn't convert \(url.lastPathComponent): \(msg.prefix(300))")
        }
    }

    /// Re-encodes to HEVC, optionally making the end flow into the start: the clip is shortened by `crossfade`
    /// seconds and its tail dissolves into its own head, so the last frame leads straight to the first.
    static func export(_ url: URL, to out: URL, quality: VideoQuality, crossfade: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError(message: "no video track") }
        let (natural, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let exportAsset: AVAsset
        var composition: AVMutableVideoComposition?
        let fade = CMTime(seconds: min(crossfade, duration.seconds / 3), preferredTimescale: 600)
        if crossfade > 0, fade.seconds > 0.05 {
            let comp = AVMutableComposition()
            guard let a = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let b = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaError(message: "couldn't build the loop")
            }
            let outLength = duration - fade
            try a.insertTimeRange(CMTimeRange(start: fade, end: duration), of: video, at: .zero)
            try b.insertTimeRange(CMTimeRange(start: .zero, duration: fade), of: video, at: outLength - fade)
            a.preferredTransform = transform
            b.preferredTransform = transform
            let vc = AVMutableVideoComposition()
            let rendered = CGRect(origin: .zero, size: natural).applying(transform)
            vc.renderSize = CGSize(width: abs(rendered.width), height: abs(rendered.height))
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(rate.rounded(), 1)))
            let head = AVMutableVideoCompositionInstruction()
            head.timeRange = CMTimeRange(start: .zero, end: outLength - fade)
            let headA = AVMutableVideoCompositionLayerInstruction(assetTrack: a)
            headA.setTransform(transform, at: .zero)
            head.layerInstructions = [headA]
            let tail = AVMutableVideoCompositionInstruction()
            tail.timeRange = CMTimeRange(start: outLength - fade, end: outLength)
            let tailA = AVMutableVideoCompositionLayerInstruction(assetTrack: a)
            tailA.setTransform(transform, at: .zero)
            tailA.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: tail.timeRange)
            let tailB = AVMutableVideoCompositionLayerInstruction(assetTrack: b)
            tailB.setTransform(transform, at: .zero)
            tail.layerInstructions = [tailA, tailB]
            vc.instructions = [head, tail]
            exportAsset = comp
            composition = vc
        } else {
            exportAsset = asset
        }
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: quality.preset) else {
            throw MediaError(message: "HEVC export isn't available on this Mac")
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = false
        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: out, as: .mov)
    }

    // MARK: Images

    static func loadImage(_ url: URL, maxSide: CGFloat? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let maxSide {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The main subjects as a white-on-black mask, via Vision's on-device segmentation.
    static func subjectMask(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let result = request.results?.first,
              let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// Where the eye goes first, as a focus point (0…1, top-left origin).
    static func focusPoint(_ image: CGImage) -> SIMD2<Double>? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let box = request.results?.first?.salientObjects?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })?.boundingBox
        else { return nil }
        return SIMD2(Double(box.midX), Double(1 - box.midY))
    }

    /// A plausible depth map with no ML depth model: the ground nearer at the bottom, subjects pulled forward.
    static func estimatedDepth(for image: CGImage, subject: CGImage?) -> CGImage? {
        let w = 1024.0, h = (1024.0 * Double(image.height) / Double(image.width)).rounded()
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: h)
        gradient.point1 = CGPoint(x: 0, y: 0)
        gradient.color0 = CIColor(red: 0.18, green: 0.18, blue: 0.18)
        gradient.color1 = CIColor(red: 0.5, green: 0.5, blue: 0.5)
        var depth = gradient.outputImage!.cropped(to: rect)
        if let subject {
            let m = CIImage(cgImage: subject)
            let scaled = m.transformed(by: CGAffineTransform(scaleX: w / m.extent.width, y: h / m.extent.height))
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = scaled.clampedToExtent()
            blur.radius = Float(w / 90)
            let soft = blur.outputImage!.cropped(to: rect)
            let lifted = soft.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.85, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.85, w: 0),
                "inputBiasVector": CIVector(x: 0.1, y: 0.1, z: 0.1, w: 0),
            ])
            depth = lifted.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: depth])
        }
        return CIContext().createCGImage(depth, from: rect, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    static func solidMask(width: Int, height: Int, white: Bool = true) -> CGImage? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.setFillColor(gray: white ? 1 : 0, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
    }
}
