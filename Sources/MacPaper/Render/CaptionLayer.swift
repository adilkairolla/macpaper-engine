import AppKit

/// A character's line over the wallpaper, styled like film subtitles: a spaced speaker name, a speaker
/// icon beside soft lavender text, and a dotted rule underneath.
@MainActor
final class CaptionLayer: CALayer {
    private static let ink = NSColor(srgbRed: 0.76, green: 0.70, blue: 0.97, alpha: 1)

    private let speakerLayer = CATextLayer()
    private let iconLayer = CALayer()
    private let textLayer = CATextLayer()
    private let ruleLayer = CAShapeLayer()
    private var text = ""
    private var speaker: String?
    private var hideWork: DispatchWorkItem?

    override init() {
        super.init()
        isGeometryFlipped = true
        opacity = 0
        actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        for layer in [speakerLayer, iconLayer, textLayer, ruleLayer] as [CALayer] {
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "path": NSNull()]
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.65
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: 2)
            addSublayer(layer)
        }
        textLayer.isWrapped = true
        ruleLayer.fillColor = nil
        ruleLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError() }

    override var contentsScale: CGFloat {
        didSet { sublayers?.forEach { $0.contentsScale = contentsScale } }
    }

    func show(_ text: String, speaker: String?, for seconds: Double) {
        hideWork?.cancel()
        let replacing = opacity > 0 && !self.text.isEmpty && self.text != text
        self.text = text
        self.speaker = speaker
        if replacing {
            fade(to: 0, duration: 0.25) { [weak self] in
                guard let self, self.text == text else { return }
                self.render()
                self.fade(to: 1, duration: 0.6)
            }
        } else {
            render()
            fade(to: 1, duration: 0.6)
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard opacity > 0 else { return }
        fade(to: 0, duration: 0.8) { [weak self] in self?.text = "" }
    }

    private func fade(to value: Float, duration: Double, then done: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = presentation()?.opacity ?? opacity
        a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        opacity = value
        add(a, forKey: "fade")
        CATransaction.commit()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        render()
    }

    private func render() {
        let w = bounds.width, h = bounds.height
        guard w > 1, h > 1, !text.isEmpty else { return }
        let size = max(12, h * 0.024)
        let small = max(8, h * 0.0095)
        let x = w * 0.045
        var y = h * 0.40

        if let speaker, !speaker.isEmpty {
            let name = NSAttributedString(string: speaker.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: small, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                .kern: small * 0.45,
            ])
            speakerLayer.string = name
            speakerLayer.frame = CGRect(x: x, y: y, width: w * 0.3, height: small * 1.4)
            speakerLayer.isHidden = false
            y += small * 2.6
        } else {
            speakerLayer.isHidden = true
        }

        let iconSize = size * 0.78
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .light)
            .applying(.init(paletteColors: [Self.ink.withAlphaComponent(0.85)]))
        iconLayer.contents = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.frame = CGRect(x: x, y: y + (size * 1.25 - iconSize) / 2, width: iconSize, height: iconSize)

        let textX = x + iconSize + size * 0.55
        let maxWidth = min(w * 0.42, w - textX - x)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.25
        let body = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .light),
            .foregroundColor: Self.ink,
            .kern: size * 0.04,
            .paragraphStyle: style,
        ])
        let fitted = body.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        textLayer.string = body
        textLayer.frame = CGRect(x: textX, y: y, width: maxWidth, height: ceil(fitted.height) + 2)

        let ruleY = (y + ceil(fitted.height) + size * 0.9).rounded() + 0.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: ruleY))
        path.addLine(to: CGPoint(x: x + w * 0.16, y: ruleY))
        ruleLayer.path = path
        ruleLayer.lineWidth = max(1, h * 0.0009)
        ruleLayer.lineDashPattern = [NSNumber(value: Double(max(1, h * 0.0012))), NSNumber(value: Double(max(2, h * 0.0035)))]
        ruleLayer.frame = bounds
    }
}
