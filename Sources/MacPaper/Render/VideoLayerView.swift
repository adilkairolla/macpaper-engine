import AppKit
import AVFoundation

/// The zero-copy path for wallpapers that are a single full-canvas video: AVPlayerLayer hands decoded
/// frames straight to the compositor, so the GPU does no work of ours at all.
@MainActor
final class VideoLayerView: NSView, SceneContent {
    let session: SceneSession
    let layerID: String
    var onFirstFrame: (() -> Void)?
    var stats: FrameStats { FrameStats(fps: Double(session.scene.fps), cpuMs: 0, gpuMs: 0, path: "Direct video") }
    var view: NSView { self }

    private var settings: RenderSettings
    private var playerLayers: [AVPlayerLayer] = []
    private var readyObservation: NSKeyValueObservation?
    private var firstFrameShown = false
    private var attachedAt = CACurrentMediaTime()
    private static let all = NSHashTable<VideoLayerView>.weakObjects()

    var stall: Stall? {
        guard session.isRunning, let pl = playerLayers.last, let player = pl.player else { return nil }
        let sharing = Self.all.allObjects.contains { other in other !== self && other.playerLayers.contains { $0.player === player } }
        if sharing { return .sharedPlayer }
        if !pl.isReadyForDisplay, CACurrentMediaTime() - attachedAt > 6 { return .layer }
        return nil
    }

    init(session: SceneSession, layerID: String, settings: RenderSettings, frame: NSRect) {
        self.session = session
        self.layerID = layerID
        self.settings = settings
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        Self.all.add(self)
        attachCurrentPlayer()
        session.observe(self) { [weak self] in self?.attachCurrentPlayer() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func attachCurrentPlayer() {
        guard let source = session.currentVideoSource(for: layerID) else { return }
        if playerLayers.last?.player === source.player { return }
        let pl = AVPlayerLayer(player: source.player)
        pl.videoGravity = .resizeAspectFill
        pl.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "opacity": NSNull()]
        pl.frame = videoFrame()
        if !playerLayers.isEmpty, session.crossfade(for: layerID) > 0 { pl.opacity = 0 }
        layer?.addSublayer(pl)
        playerLayers.append(pl)
        attachedAt = CACurrentMediaTime()
        readyObservation = pl.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak pl] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let pl else { return }
                    self.becameReady(pl)
                }
            }
        }
    }

    private func becameReady(_ pl: AVPlayerLayer) {
        // The callback is async: a newer clip's layer may have been attached since, and must not be retired.
        guard pl === playerLayers.last else { return }
        let old = playerLayers.filter { $0 !== pl }
        let retire = {
            for layer in old {
                layer.removeFromSuperlayer()
                layer.player = nil
            }
        }
        let fade = session.crossfade(for: layerID)
        if pl.opacity == 0, fade > 0 {
            CATransaction.begin()
            CATransaction.setCompletionBlock(retire)
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = fade
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.25, 1)
            pl.opacity = 1
            pl.add(a, forKey: "crossfade")
            CATransaction.commit()
        } else {
            pl.opacity = 1
            retire()
        }
        playerLayers = [pl]
        readyObservation = nil
        if !firstFrameShown {
            firstFrameShown = true
            onFirstFrame?()
        }
    }

    /// The canvas, scaled to cover the view and offset so the focus point stays in view.
    private func videoFrame() -> CGRect {
        guard bounds.width >= 1, bounds.height >= 1 else { return bounds }
        let canvas = session.scene.canvas
        let region = SceneEncoder.region(canvas: canvas, output: bounds.size, focus: settings.focus ?? session.wallpaper.manifest.focus, span: settings.span)
        let w = bounds.width / CGFloat(region.z)
        let h = bounds.height / CGFloat(region.w)
        let x = -CGFloat(region.x) * w
        let yTop = CGFloat(region.y) * h
        return CGRect(x: x, y: -(h - bounds.height - yTop), width: w, height: h)
    }

    override func layout() {
        super.layout()
        let f = videoFrame()
        playerLayers.forEach { $0.frame = f }
    }

    func apply(_ settings: RenderSettings) {
        self.settings = settings
        needsLayout = true
    }

    func setPaused(_ paused: Bool) {
        session.setPlaying(!paused, consumer: self)
    }

    func setPointer(_ point: SIMD2<Float>?) {}

    func tearDown() {
        readyObservation = nil
        Self.all.remove(self)
        session.unobserve(self)
        for case let pl as AVPlayerLayer in layer?.sublayers ?? [] {
            pl.player = nil
            pl.removeFromSuperlayer()
        }
        playerLayers.removeAll()
    }
}
