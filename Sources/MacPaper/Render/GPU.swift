import CoreVideo
import Metal
import MetalKit

struct FrameUniforms {
    var time: Float = 0
    var delta: Float = 0
    var resolution: SIMD2<Float> = .zero
    var canvas: SIMD2<Float> = .zero
    var mouse: SIMD2<Float> = SIMD2(0.5, 0.5)
    var parallax: SIMD2<Float> = .zero
    var daylight: Float = 1
    var dark: Float = 0
    var audioLevel: Float = 0
    var pad: Float = 0
    var audio: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
}

struct LayerUniforms {
    var region: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var rect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var mediaFit: SIMD4<Float> = SIMD4(1, 1, 0, 0)
    var shift: SIMD2<Float> = .zero
    var opacity: Float = 1
    var composite: Float = 0
    var zoom: Float = 1
    var depthStrength: Float = 0
    var blend: Int32 = 0
    var flags: Int32 = 0
    var yuv: simd_float4x4 = matrix_identity_float4x4
}

struct GradeUniforms {
    var brightness: Float = 1
    var contrast: Float = 1
    var saturation: Float = 1
    var warmth: Float = 0

    var isIdentity: Bool { brightness == 1 && contrast == 1 && saturation == 1 && warmth == 0 }
}

/// The process-wide Metal device, queue and built-in pipelines.
@MainActor
final class GPU {
    static let shared = GPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache
    let loader: MTKTextureLoader
    let pixelFormat = MTLPixelFormat.bgra8Unorm
    private(set) lazy var dummy: MTLTexture = makeDummy()
    private var builtins: [String: MTLRenderPipelineState] = [:]
    private var computes: [String: MTLComputePipelineState] = [:]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available")
        }
        self.device = device
        self.queue = queue
        queue.label = "MacPaper"
        do {
            library = try device.makeLibrary(source: ShaderSource.builtins, options: Self.compileOptions)
        } catch {
            fatalError("Built-in shaders failed to compile: \(error)")
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!
        loader = MTKTextureLoader(device: device)
    }

    nonisolated static var compileOptions: MTLCompileOptions {
        let o = MTLCompileOptions()
        o.mathMode = .fast
        o.languageVersion = .version3_1
        return o
    }

    private func makeDummy() -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        var px: UInt32 = 0
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }

    /// `composite` pipelines write the shader's own blend result; the others use fixed-function blending.
    func makePipeline(fragment: MTLFunction, vertex: MTLFunction? = nil, blend: Blend?) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex ?? library.makeFunction(name: "mp_vertex")
        d.fragmentFunction = fragment
        let att = d.colorAttachments[0]!
        att.pixelFormat = pixelFormat
        if let blend {
            att.isBlendingEnabled = true
            att.alphaBlendOperation = .add
            att.rgbBlendOperation = .add
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            switch blend {
            case .normal:
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            case .add:
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .one
            case .screen:
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .oneMinusSourceColor
            case .multiply:
                att.sourceRGBBlendFactor = .destinationColor
                att.destinationRGBBlendFactor = .zero
            }
        }
        return try device.makeRenderPipelineState(descriptor: d)
    }

    func builtin(_ name: String, blend: Blend?) -> MTLRenderPipelineState {
        let key = "\(name)|\(blend?.rawValue ?? "opaque")"
        if let p = builtins[key] { return p }
        let p = try! makePipeline(fragment: library.makeFunction(name: name)!, blend: blend)
        builtins[key] = p
        return p
    }

    func particlePipeline(blend: Blend) -> MTLRenderPipelineState {
        let key = "particles|\(blend.rawValue)"
        if let p = builtins[key] { return p }
        let p = try! makePipeline(
            fragment: library.makeFunction(name: "mp_particle_fragment")!,
            vertex: library.makeFunction(name: "mp_particle_vertex")!,
            blend: blend
        )
        builtins[key] = p
        return p
    }

    func compute(_ name: String) -> MTLComputePipelineState {
        if let c = computes[name] { return c }
        let c = try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        computes[name] = c
        return c
    }

    func makeTarget(width: Int, height: Int, label: String) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        t.label = label
        return t
    }
}
