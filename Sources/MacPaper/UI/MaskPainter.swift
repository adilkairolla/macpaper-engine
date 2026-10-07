import SwiftUI

/// Paint where an effect applies. White = effect on. Starts from quick fills (subject, sky…) and refines with a brush.
struct MaskPainter: View {
    let image: CGImage?
    let subject: CGImage?
    let hint: String
    let initial: CGImage?
    let done: (CGImage?) -> Void

    private struct Stroke {
        var points: [CGPoint]
        var radius: CGFloat
        var erase: Bool
    }

    @State private var base: CGImage?
    @State private var strokes: [Stroke] = []
    @State private var current: Stroke?
    @State private var brush: Double = 0.05
    @State private var erasing = false
    @State private var rendered: CGImage?
    @State private var overlay: CGImage?

    private var maskSize: CGSize {
        let w = 1024.0
        guard let image else { return CGSize(width: w, height: 576) }
        return CGSize(width: w, height: (w * Double(image.height) / Double(max(image.width, 1))).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Paint Mask").font(.title3.weight(.semibold))
                if !hint.isEmpty { Text(hint).foregroundStyle(.secondary) }
                Spacer()
            }
            canvas
            HStack(spacing: 10) {
                Picker("", selection: $erasing) {
                    Label("Paint", systemImage: "paintbrush.pointed").tag(false)
                    Label("Erase", systemImage: "eraser").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Text("Brush")
                Slider(value: $brush, in: 0.01...0.2).frame(width: 140)
                Spacer()
                Menu("Fill") {
                    Button("Everything") { reset(MediaTools.solidMask(width: Int(maskSize.width), height: Int(maskSize.height), white: true)) }
                    Button("Nothing") { reset(MediaTools.solidMask(width: Int(maskSize.width), height: Int(maskSize.height), white: false)) }
                    if subject != nil {
                        Divider()
                        Button("Subject") { reset(subject.flatMap { scaled($0, invert: false) }) }
                        Button("Background") { reset(subject.flatMap { scaled($0, invert: true) }) }
                    }
                    Divider()
                    Button("Top Half") { reset(gradient(top: true)) }
                    Button("Bottom Half") { reset(gradient(top: false)) }
                }
                .fixedSize()
                Button("Undo") { _ = strokes.popLast(); redraw() }
                    .disabled(strokes.isEmpty)
                    .keyboardShortcut("z")
            }
            HStack {
                Spacer()
                Button("Cancel") { done(initial) }.keyboardShortcut(.cancelAction)
                Button("Done") { done(rendered) }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 600)
        .onAppear {
            base = initial.flatMap { scaled($0, invert: false) } ?? MediaTools.solidMask(width: Int(maskSize.width), height: Int(maskSize.height), white: false)
            redraw()
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                if let image { Image(decorative: image, scale: 1).resizable() } else { Color.black }
                if let overlay { Image(decorative: overlay, scale: 1).resizable() }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let p = CGPoint(x: g.location.x / geo.size.width, y: g.location.y / geo.size.height)
                    if current == nil { current = Stroke(points: [], radius: brush, erase: erasing) }
                    current?.points.append(p)
                    redraw()
                }
                .onEnded { _ in
                    if let c = current { strokes.append(c) }
                    current = nil
                    redraw()
                })
        }
        .aspectRatio(maskSize.width / maskSize.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func reset(_ image: CGImage?) {
        base = image
        strokes = []
        redraw()
    }

    private func context() -> CGContext? {
        CGContext(data: nil, width: Int(maskSize.width), height: Int(maskSize.height), bitsPerComponent: 8, bytesPerRow: Int(maskSize.width),
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    private func redraw() {
        guard let ctx = context() else { return }
        let w = maskSize.width, h = maskSize.height
        if let base { ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h)) } else {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes + (current.map { [$0] } ?? []) {
            ctx.setStrokeColor(gray: s.erase ? 0 : 1, alpha: 1)
            ctx.setFillColor(gray: s.erase ? 0 : 1, alpha: 1)
            ctx.setLineWidth(s.radius * 2 * h)
            ctx.setShadow(offset: .zero, blur: s.radius * h * 0.6, color: CGColor(gray: s.erase ? 0 : 1, alpha: 1))
            let pts = s.points.map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }
            if pts.count == 1 {
                let r = s.radius * h
                ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
            } else if let first = pts.first {
                ctx.beginPath()
                ctx.move(to: first)
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
        }
        rendered = ctx.makeImage()
        overlay = rendered.flatMap(tint)
    }

    private func tint(_ mask: CGImage) -> CGImage? {
        let rect = CGRect(origin: .zero, size: maskSize)
        guard let ctx = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clip(to: rect, mask: mask)
        ctx.setFillColor(red: 1, green: 0.25, blue: 0.35, alpha: 0.55)
        ctx.fill(rect)
        return ctx.makeImage()
    }

    private func scaled(_ mask: CGImage, invert: Bool) -> CGImage? {
        guard let ctx = context() else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(mask, in: CGRect(origin: .zero, size: maskSize))
        guard invert, let data = ctx.data else { return ctx.makeImage() }
        let n = Int(maskSize.width * maskSize.height)
        let p = data.bindMemory(to: UInt8.self, capacity: n)
        for i in 0..<n { p[i] = 255 - p[i] }
        return ctx.makeImage()
    }

    private func gradient(top: Bool) -> CGImage? {
        guard let ctx = context() else { return nil }
        let space = CGColorSpaceCreateDeviceGray()
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray
        guard let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.4, 0.6]) else { return nil }
        let h = maskSize.height
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top ? h : 0), end: CGPoint(x: 0, y: top ? 0 : h), options: [])
        return ctx.makeImage()
    }
}
