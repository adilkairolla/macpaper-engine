import Metal

struct EmitterUniforms {
    var area: SIMD4<Float> = .zero
    var color: SIMD4<Float> = .one
    var colorEnd: SIMD4<Float> = .one
    var lifetime: SIMD2<Float> = .zero
    var speed: SIMD2<Float> = .zero
    var size: SIMD2<Float> = .zero
    var fade: SIMD2<Float> = .zero
    var gravity: SIMD2<Float> = .zero
    var wind: SIMD2<Float> = .zero
    var spin: SIMD2<Float> = .zero
    var mouse: SIMD2<Float> = SIMD2(-10, -10)
    var direction: Float = 0
    var spread: Float = 0
    var turbulence: Float = 0
    var turbulenceScale: Float = 1
    var twinkle: Float = 0
    var stretch: Float = 0
    var mouseStrength: Float = 0
    var aspect: Float = 1
    var dt: Float = 0
    var time: Float = 0
    var count: Int32 = 0
    var shape: Int32 = 0
    var hasMask: Int32 = 0
    var hasTexture: Int32 = 0
}

/// GPU-simulated particles for one layer on one display.
@MainActor
final class ParticleSystem {
    static let particleStride = 48

    private(set) var spec: ParticleSpec
    private var buffer: MTLBuffer
    private var capacity: Int
    private var needsInit = true
    private var initMask: String?

    init(spec: ParticleSpec) {
        self.spec = spec
        capacity = max(1, spec.count)
        buffer = GPU.shared.device.makeBuffer(length: capacity * Self.particleStride, options: .storageModePrivate)!
    }

    func update(_ spec: ParticleSpec) {
        if spec.count > capacity {
            capacity = spec.count
            buffer = GPU.shared.device.makeBuffer(length: capacity * Self.particleStride, options: .storageModePrivate)!
            needsInit = true
        }
        if spec.count != self.spec.count || spec.area != self.spec.area || spec.mask != self.spec.mask {
            needsInit = true
        }
        self.spec = spec
    }

    private func uniforms(dt: Double, time: Double, mouse: SIMD2<Float>?, aspect: Float, mask: MTLTexture?, sprite: MTLTexture?) -> EmitterUniforms {
        var e = EmitterUniforms()
        e.area = spec.area.simd
        e.color = spec.color.simd
        e.colorEnd = spec.colorEnd.simd
        e.lifetime = SIMD2(Float(max(0.05, spec.lifetime.lo)), Float(max(0.05, spec.lifetime.hi)))
        e.speed = spec.speed.simd
        e.size = spec.size.simd
        e.fade = spec.fade.simd
        e.gravity = spec.gravity.float
        e.wind = spec.wind.float
        e.spin = spec.spin.simd
        e.mouse = mouse ?? SIMD2(-10, -10)
        e.direction = Float(spec.direction)
        e.spread = Float(spec.spread)
        e.turbulence = Float(spec.turbulence)
        e.turbulenceScale = Float(spec.turbulenceScale)
        e.twinkle = Float(spec.twinkle)
        e.stretch = Float(spec.stretch)
        e.mouseStrength = mouse == nil ? 0 : Float(spec.mouse)
        e.aspect = aspect
        e.dt = Float(min(max(dt, 0), 0.1))
        e.time = Float(time)
        e.count = Int32(spec.count)
        e.shape = spec.shape.index
        e.hasMask = mask == nil ? 0 : 1
        e.hasTexture = sprite == nil ? 0 : 1
        return e
    }

    func simulate(_ cb: MTLCommandBuffer, dt: Double, time: Double, mouse: SIMD2<Float>?, aspect: Float, mask: MTLTexture?) {
        guard spec.count > 0, let enc = cb.makeComputeCommandEncoder() else { return }
        let gpu = GPU.shared
        let pipeline = gpu.compute(needsInit ? "mp_particles_init" : "mp_particles_step")
        var e = uniforms(dt: needsInit ? 0 : dt, time: time, mouse: mouse, aspect: aspect, mask: mask, sprite: nil)
        enc.label = "particles"
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBytes(&e, length: MemoryLayout<EmitterUniforms>.stride, index: 1)
        enc.setTexture(mask ?? gpu.dummy, index: 0)
        let w = pipeline.threadExecutionWidth
        enc.dispatchThreads(MTLSize(width: spec.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        needsInit = false
    }

    func draw(_ enc: MTLRenderCommandEncoder, layer: inout LayerUniforms, blend: Blend, time: Double, aspect: Float, sprite: MTLTexture?) {
        guard spec.count > 0 else { return }
        let gpu = GPU.shared
        var e = uniforms(dt: 0, time: time, mouse: nil, aspect: aspect, mask: nil, sprite: sprite)
        enc.setRenderPipelineState(gpu.particlePipeline(blend: blend))
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&e, length: MemoryLayout<EmitterUniforms>.stride, index: 1)
        enc.setVertexBytes(&layer, length: MemoryLayout<LayerUniforms>.stride, index: 2)
        enc.setFragmentTexture(sprite ?? gpu.dummy, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: spec.count)
    }
}
