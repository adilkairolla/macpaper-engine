import AppKit
import Metal
import MetalFX

/// What a display contributes to a frame on top of the shared session state.
struct FrameInput {
    var hostTime: CFTimeInterval
    var dt: Double
    var outputSize: CGSize
    var renderScale: Double
    var focus: SIMD2<Double>
    var parallax: SIMD2<Float>
    var parallaxStrength: Double
    var pointer: SIMD2<Float>?
    var grade: GradeUniforms
    var daylight: Float
    var dark: Float
}

/// Encodes one frame of a scene: layers bottom to top, ping-ponging between two targets only where a
/// layer reads what's below it, optional MetalFX upscale, then the colour grade.
@MainActor
final class SceneEncoder {
    let session: SceneSession
    private var targets: [MTLTexture?] = [nil, nil]
    private var targetSize = CGSize.zero
    private var framesWithoutTargets = 0
    private var upscaled: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey = ""
    private var particles: [String: ParticleSystem] = [:]

    init(session: SceneSession) {
        self.session = session
    }

    nonisolated static func region(canvas: CGSize, output: CGSize, focus: SIMD2<Double>) -> SIMD4<Float> {
        let canvasAspect = canvas.width / max(canvas.height, 1)
        let outAspect = output.width / max(output.height, 1)
        if outAspect > canvasAspect {
            let h = canvasAspect / outAspect
            let y = min(max(focus.y - h / 2, 0), 1 - h)
            return SIMD4(0, Float(y), 1, Float(h))
        } else {
            let w = outAspect / canvasAspect
            let x = min(max(focus.x - w / 2, 0), 1 - w)
            return SIMD4(Float(x), 0, Float(w), 1)
        }
    }

    nonisolated static func mediaFit(media: CGSize, rect: NormRect, canvas: CGSize, fit: Fit) -> SIMD4<Float> {
        guard fit != .stretch, media.width > 0, media.height > 0 else { return SIMD4(1, 1, 0, 0) }
        let rw = rect.w * canvas.width, rh = rect.h * canvas.height
        let s = fit == .fill ? max(rw / media.width, rh / media.height) : min(rw / media.width, rh / media.height)
        let fx = rw / (media.width * s), fy = rh / (media.height * s)
        return SIMD4(Float(fx), Float(fy), Float((1 - fx) / 2), Float((1 - fy) / 2))
    }

    /// Offscreen targets are made on first use and dropped after a while without one, e.g. once a grade is reset.
    private func target(_ i: Int, size: CGSize) -> MTLTexture {
        if size != targetSize {
            targetSize = size
            targets = [nil, nil]
        }
        if let t = targets[i] { return t }
        let t = GPU.shared.makeTarget(width: Int(size.width), height: Int(size.height), label: "scene-\(i)")
        targets[i] = t
        return t
    }

    private func ensureScaler(input: CGSize, output: CGSize) -> MTLFXSpatialScaler? {
        let key = "\(input)->\(output)"
        if key == scalerKey { return scaler }
        scalerKey = key
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = Int(input.width)
        d.inputHeight = Int(input.height)
        d.outputWidth = Int(output.width)
        d.outputHeight = Int(output.height)
        d.colorTextureFormat = GPU.shared.pixelFormat
        d.outputTextureFormat = GPU.shared.pixelFormat
        d.colorProcessingMode = .perceptual
        scaler = d.makeSpatialScaler(device: GPU.shared.device)
        if let scaler {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPU.shared.pixelFormat, width: d.outputWidth, height: d.outputHeight, mipmapped: false)
            td.usage = scaler.outputTextureUsage.union(.shaderRead)
            td.storageMode = .private
            upscaled = GPU.shared.device.makeTexture(descriptor: td)
        } else {
            upscaled = nil
        }
        return scaler
    }

    private enum Op {
        case media(LayerUniforms, MTLTexture, MTLTexture?, MTLTexture?, Blend)
        case shader(LayerUniforms, ShaderProgram, [UInt8], [MTLTexture], Blend, Bool)
        case particles(LayerUniforms, ParticleSystem, MTLTexture?, Blend)
        case grade(GradeUniforms)

        var composite: Bool {
            switch self {
            case .shader(_, _, _, _, _, let c): c
            case .grade: true
            default: false
            }
        }
    }

    /// Encodes the frame into `output`. Returns false when nothing could be drawn yet.
    @discardableResult
    func encode(_ cb: MTLCommandBuffer, output: MTLTexture, input: FrameInput) -> Bool {
        let gpu = GPU.shared
        let scene = session.scene
        let time = session.time(at: input.hostTime)
        let simDt = session.isRunning ? input.dt * session.speed : 0
        let canvas = scene.canvas
        let aspect = Float(canvas.width / max(canvas.height, 1))
        let region = Self.region(canvas: canvas, output: input.outputSize, focus: input.focus)
        // Upscaling only pays off for shaders, which cost per pixel; video and images are cheaper drawn at full size.
        let shaded = scene.layers.contains { l in
            if case .shader = l.content { return l.visible }
            return false
        }
        let scale = shaded ? min(max(input.renderScale, 0.25), 1) : 1
        let renderSize = CGSize(width: (input.outputSize.width * scale).rounded(), height: (input.outputSize.height * scale).rounded())
        let upscale = scale < 0.999 ? ensureScaler(input: renderSize, output: input.outputSize) : nil

        var frame = FrameUniforms()
        frame.time = Float(time)
        frame.delta = Float(simDt)
        frame.resolution = SIMD2(Float(renderSize.width), Float(renderSize.height))
        frame.canvas = SIMD2(Float(canvas.width), Float(canvas.height))
        let pointerCanvas = input.pointer.map { SIMD2(region.x + $0.x * region.z, region.y + $0.y * region.w) }
        frame.mouse = pointerCanvas ?? SIMD2(0.5, 0.5)
        frame.parallax = input.parallax
        frame.daylight = input.daylight
        frame.dark = input.dark
        let spectrum = session.spectrum
        frame.audioLevel = spectrum.level
        frame.audio = spectrum.packed

        var ops: [Op] = []
        var liveParticles: Set<String> = []
        for layer in scene.layers where layer.visible {
            var weight = layer.opacity
            switch layer.daypart {
            case .always: break
            case .day: weight *= Double(input.daylight)
            case .night: weight *= Double(1 - input.daylight)
            }
            guard weight > 0.001 else { continue }
            var u = LayerUniforms()
            u.region = region
            u.rect = layer.rect.simd
            u.opacity = Float(weight)
            u.blend = Int32(Blend.allCases.firstIndex(of: layer.blend)!)
            let p = Float(layer.parallax * input.parallaxStrength)
            u.shift = input.parallax * p
            u.zoom = 1 + 2 * abs(p)
            switch layer.content {
            case .image(let spec):
                guard let tex = session.texture(spec.src) else { continue }
                u.mediaFit = Self.mediaFit(media: CGSize(width: tex.width, height: tex.height), rect: layer.rect, canvas: canvas, fit: layer.fit)
                u.flags = 4
                let depth = session.texture(spec.depth)
                if depth != nil {
                    u.flags |= 1
                    let ds = Float(spec.depthStrength * input.parallaxStrength)
                    u.depthStrength = ds
                    u.zoom += abs(ds)
                }
                ops.append(.media(u, tex, nil, depth, layer.blend))
            case .video:
                for (frameTex, alpha) in session.videoFrames(for: layer.id, hostTime: input.hostTime) {
                    var v = u
                    v.opacity *= alpha
                    v.mediaFit = Self.mediaFit(media: frameTex.size, rect: layer.rect, canvas: canvas, fit: layer.fit)
                    v.flags = frameTex.chroma != nil ? 2 : 4
                    v.yuv = frameTex.yuv
                    ops.append(.media(v, frameTex.luma, frameTex.chroma, nil, layer.blend))
                }
            case .shader(let spec):
                guard let program = session.program(for: layer.id) else { continue }
                let textures = spec.textures.map { session.texture($0.path) ?? gpu.dummy }
                u.composite = program.readsSource ? 1 : 0
                ops.append(.shader(u, program, program.pack(spec.params), textures, layer.blend, program.readsSource))
            case .particles(let spec):
                let system: ParticleSystem
                if let s = particles[layer.id] { s.update(spec); system = s } else {
                    system = ParticleSystem(spec: spec)
                    particles[layer.id] = system
                }
                liveParticles.insert(layer.id)
                system.simulate(cb, dt: simDt, time: time, mouse: pointerCanvas, aspect: aspect, mask: session.texture(spec.mask))
                let sprite = spec.shape == .texture ? session.texture(spec.texture) : nil
                ops.append(.particles(u, system, sprite, layer.blend))
            }
        }
        for id in particles.keys where !liveParticles.contains(id) { particles[id] = nil }
        if !input.grade.isIdentity { ops.append(.grade(input.grade)) }

        // Split into passes: a pass starts at every layer that reads the composite below it.
        // An empty first group still clears to the background, which is then what the first reader sees.
        var groups: [[Op]] = [[]]
        for op in ops {
            if op.composite {
                groups.append([op])
            } else {
                groups[groups.count - 1].append(op)
            }
        }

        let finalToOutput = upscale == nil
        if groups.count > 1 || !finalToOutput {
            framesWithoutTargets = 0
        } else if targets.contains(where: { $0 != nil }) {
            framesWithoutTargets += 1
            if framesWithoutTargets > 600 { targets = [nil, nil] }
        }
        var previous: MTLTexture? = nil
        for (i, group) in groups.enumerated() {
            let isLast = i == groups.count - 1
            let dest: MTLTexture
            if isLast && finalToOutput {
                dest = output
            } else {
                dest = target(i % 2, size: renderSize)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = dest
            pass.colorAttachments[0].storeAction = .store
            if i == 0 {
                let bg = scene.background
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
            } else {
                pass.colorAttachments[0].loadAction = .dontCare
            }
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
            for op in group {
                draw(op, enc: enc, frame: &frame, source: previous ?? gpu.dummy, time: time, aspect: aspect)
            }
            enc.endEncoding()
            previous = dest
        }

        if let upscale, let upscaled, let source = previous {
            upscale.colorTexture = source
            upscale.outputTexture = upscaled
            upscale.inputContentWidth = Int(renderSize.width)
            upscale.inputContentHeight = Int(renderSize.height)
            upscale.encode(commandBuffer: cb)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                var u = LayerUniforms()
                enc.setRenderPipelineState(gpu.builtin("mp_copy", blend: nil))
                enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 2)
                enc.setFragmentTexture(upscaled, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        return true
    }

    private func draw(_ op: Op, enc: MTLRenderCommandEncoder, frame: inout FrameUniforms, source: MTLTexture, time: Double, aspect: Float) {
        let gpu = GPU.shared
        switch op {
        case .media(var u, let tex, let chroma, let depth, let blend):
            enc.setRenderPipelineState(gpu.builtin("mp_media", blend: blend))
            enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 2)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 2)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentTexture(tex, index: 1)
            enc.setFragmentTexture(chroma ?? gpu.dummy, index: 2)
            enc.setFragmentTexture(depth ?? gpu.dummy, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        case .shader(var u, let program, var params, let textures, let blend, let composite):
            guard let pipeline = program.pipeline(blend: composite ? nil : blend) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 2)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentBytes(&params, length: params.count, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 2)
            enc.setFragmentTexture(source, index: 0)
            for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i + 1) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        case .particles(var u, let system, let sprite, let blend):
            system.draw(enc, layer: &u, blend: blend, time: time, aspect: aspect, sprite: sprite)
        case .grade(var g):
            var u = LayerUniforms()
            enc.setRenderPipelineState(gpu.builtin("mp_grade", blend: nil))
            enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 2)
            enc.setFragmentBytes(&g, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            enc.setFragmentTexture(source, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }
}
