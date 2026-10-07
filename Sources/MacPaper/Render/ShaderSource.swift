import Foundation

/// The Metal source shared by every built-in and user pass: vertex stage, system structs and helpers.
enum ShaderSource {
    static let common = #"""
#include <metal_stdlib>
using namespace metal;

struct Frame {
    float time;
    float delta;
    float2 resolution;
    float2 canvas;
    float2 mouse;
    float2 parallax;
    float daylight;
    float dark;
    float audioLevel;
    float _pad;
    float4 audio[4];
};

struct MPLayer {
    float4 region;      // canvas window seen by the output: x, y, w, h
    float4 rect;        // layer rect on the canvas
    float4 mediaFit;    // media-uv scale (xy) and offset (zw) inside the rect
    float2 shift;       // parallax shift in canvas uv
    float opacity;
    float composite;    // 1: blend with `source` in the shader, 0: hardware blending
    float zoom;         // overscan so parallax never reveals edges
    float depthStrength;
    int blend;
    int flags;          // 1: has depth, 2: biplanar YUV, 4: media has alpha
    float4x4 yuv;
};

struct MPVertexOut {
    float4 position [[position]];
    float2 uv;
    float2 screen;
};

vertex MPVertexOut mp_vertex(uint vid [[vertex_id]], constant MPLayer& layer [[buffer(2)]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    MPVertexOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    o.screen = float2(p.x, 1.0 - p.y);
    o.uv = layer.region.xy + o.screen * layer.region.zw;
    return o;
}

static inline float mp_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float2 mp_hash2(float2 p) {
    float n = mp_hash(p);
    return float2(n, mp_hash(p + n * 17.17));
}

static inline float mp_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = mp_hash(i);
    float b = mp_hash(i + float2(1, 0));
    float c = mp_hash(i + float2(0, 1));
    float d = mp_hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float mp_fbm(float2 p, int octaves) {
    float v = 0.0, a = 0.5, norm = 0.0;
    for (int i = 0; i < min(octaves, 10); i++) {
        v += a * mp_noise(p);
        norm += a;
        p = p * 2.03 + float2(17.1, 9.2);
        a *= 0.5;
    }
    return v / max(norm, 1e-4);
}

static inline float mp_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static inline float2 mp_rotate(float2 p, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static inline float mp_aspect(Frame f) { return f.canvas.x / max(f.canvas.y, 1.0); }

static inline float3 mp_hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

static inline float3 mp_rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static inline float2 mp_layer_uv(float2 canvasUV, constant MPLayer& layer) {
    float2 centered = (canvasUV - layer.shift - 0.5) / layer.zoom + 0.5;
    return centered;
}

static inline float3 mp_blend_rgb(float3 dst, float3 src, int mode) {
    switch (mode) {
        case 1: return dst + src;
        case 2: return 1.0 - (1.0 - dst) * (1.0 - src);
        case 3: return dst * src;
        default: return src;
    }
}

/// Straight-alpha colour in, premultiplied out; composited in the shader when the layer reads `source`.
static inline float4 mp_finish(float4 c, constant MPLayer& layer, texture2d<float> source, float2 screen) {
    float a = clamp(c.a, 0.0, 1.0) * layer.opacity;
    if (layer.composite > 0.5) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 dst = source.sample(s, screen);
        float3 mixed = mp_blend_rgb(dst.rgb, c.rgb, layer.blend);
        return float4(mix(dst.rgb, mixed, a), 1.0);
    }
    if (layer.blend == 3) return float4(mix(float3(1.0), c.rgb, a), a);
    return float4(c.rgb * a, a);
}
"""#

    /// Built-in passes: media (image/video), colour grade, particles.
    static let builtins = common + #"""

static inline float4 mp_sample_media(texture2d<float> tex, texture2d<float> chroma, float2 uv, constant MPLayer& layer) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    if (layer.flags & 2) {
        float y = tex.sample(s, uv).r;
        float2 cbcr = chroma.sample(s, uv).rg;
        float4 rgb = layer.yuv * float4(y, cbcr, 1.0);
        return float4(saturate(rgb.rgb), 1.0);
    }
    float4 c = tex.sample(s, uv);
    if (layer.flags & 4) return c;
    return float4(c.rgb, 1.0);
}

fragment float4 mp_media(MPVertexOut v [[stage_in]],
                         constant Frame& frame [[buffer(0)]],
                         constant MPLayer& layer [[buffer(2)]],
                         texture2d<float> source [[texture(0)]],
                         texture2d<float> tex [[texture(1)]],
                         texture2d<float> chroma [[texture(2)]],
                         texture2d<float> depth [[texture(3)]]) {
    float2 canvasUV = mp_layer_uv(v.uv, layer);
    float2 local = (canvasUV - layer.rect.xy) / layer.rect.zw;
    float2 uv = local * layer.mediaFit.xy + layer.mediaFit.zw;
    if (layer.flags & 1) {
        constexpr sampler ds(filter::linear, address::clamp_to_edge);
        float2 dir = frame.parallax * layer.depthStrength;
        // A few steps of relief mapping keep near objects from smearing over the background.
        float2 probe = uv;
        for (int i = 0; i < 4; i++) {
            float d = depth.sample(ds, probe).r;
            probe = uv - dir * (d - 0.5);
        }
        uv = probe;
    }
    if (any(local < 0.0) || any(local > 1.0) || any(uv < -0.001) || any(uv > 1.001)) {
        return mp_finish(float4(0), layer, source, v.screen);
    }
    return mp_finish(mp_sample_media(tex, chroma, uv, layer), layer, source, v.screen);
}

fragment float4 mp_fill(MPVertexOut v [[stage_in]], constant float4& color [[buffer(0)]]) {
    return float4(color.rgb * color.a, color.a);
}

struct Grade {
    float brightness;
    float contrast;
    float saturation;
    float warmth;
};

fragment float4 mp_grade(MPVertexOut v [[stage_in]],
                         constant Grade& g [[buffer(0)]],
                         texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = source.sample(s, v.screen).rgb;
    c *= g.brightness;
    c = (c - 0.5) * g.contrast + 0.5;
    float l = mp_luma(c);
    c = mix(float3(l), c, g.saturation);
    c *= float3(1.0 + g.warmth * 0.12, 1.0 + g.warmth * 0.02, 1.0 - g.warmth * 0.12);
    return float4(saturate(c), 1.0);
}

fragment float4 mp_copy(MPVertexOut v [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(source.sample(s, v.screen).rgb, 1.0);
}

// MARK: Particles

struct Particle {
    float2 pos;
    float2 vel;
    float life;
    float maxLife;
    float size;
    float seed;
    float angle;
    float spin;
    float generation;
    float _pad;
};

struct Emitter {
    float4 area;
    float4 color;
    float4 colorEnd;
    float2 lifetime;
    float2 speed;
    float2 size;
    float2 fade;
    float2 gravity;
    float2 wind;
    float2 spin;
    float2 mouse;
    float direction;
    float spread;
    float turbulence;
    float turbulenceScale;
    float twinkle;
    float stretch;
    float mouseStrength;
    float aspect;
    float dt;
    float time;
    int count;
    int shape;
    int hasMask;
    int hasTexture;
};

static inline float rnd(float seed, float k) { return mp_hash(float2(seed * 0.6180339 + k, seed * 0.3141 + k * 7.13)); }

static inline void mp_spawn(device Particle& p, constant Emitter& e, texture2d<float> mask, uint id) {
    float seed = float(id) + p.generation * 9973.0 + 0.5;
    float2 pos = e.area.xy + float2(rnd(seed, 1.0), rnd(seed, 2.0)) * e.area.zw;
    if (e.hasMask) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        for (int i = 0; i < 8; i++) {
            float2 c = float2(rnd(seed, 10.0 + i), rnd(seed, 20.0 + i));
            if (mask.sample(s, c, level(0)).r > 0.5) { pos = c; break; }
        }
    }
    float ang = (e.direction + (rnd(seed, 3.0) - 0.5) * 2.0 * e.spread) * M_PI_F / 180.0;
    float spd = mix(e.speed.x, e.speed.y, rnd(seed, 4.0));
    p.pos = pos;
    p.vel = float2(cos(ang) / e.aspect, sin(ang)) * spd;
    p.maxLife = mix(e.lifetime.x, e.lifetime.y, rnd(seed, 5.0));
    p.life = 0.0;
    p.size = mix(e.size.x, e.size.y, rnd(seed, 6.0));
    p.seed = rnd(seed, 7.0);
    p.angle = rnd(seed, 8.0) * 6.2831853;
    p.spin = mix(e.spin.x, e.spin.y, rnd(seed, 9.0));
}

kernel void mp_particles_init(device Particle* ps [[buffer(0)]],
                              constant Emitter& e [[buffer(1)]],
                              texture2d<float> mask [[texture(0)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uint(e.count)) return;
    device Particle& p = ps[id];
    p.generation = 0.0;
    mp_spawn(p, e, mask, id);
    // Stagger ages so the field starts full instead of all spawning at once.
    p.life = rnd(float(id) + 0.25, 11.0) * p.maxLife;
    p.pos += p.vel * p.life;
}

kernel void mp_particles_step(device Particle* ps [[buffer(0)]],
                              constant Emitter& e [[buffer(1)]],
                              texture2d<float> mask [[texture(0)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uint(e.count)) return;
    device Particle& p = ps[id];
    p.life += e.dt;
    if (p.life >= p.maxLife) {
        p.generation += 1.0;
        mp_spawn(p, e, mask, id);
        return;
    }
    float2 acc = e.gravity + e.wind;
    if (e.turbulence > 0.0) {
        float2 q = p.pos * e.turbulenceScale + float2(e.time * 0.05, p.seed * 13.0);
        float eps = 0.01;
        float n1 = mp_noise(q + float2(0, eps)), n2 = mp_noise(q - float2(0, eps));
        float n3 = mp_noise(q + float2(eps, 0)), n4 = mp_noise(q - float2(eps, 0));
        float2 curl = float2(n1 - n2, -(n3 - n4)) / (2.0 * eps);
        acc += curl * e.turbulence;
    }
    if (e.mouseStrength != 0.0) {
        float2 d = (p.pos - e.mouse) * float2(e.aspect, 1.0);
        float dist = length(d);
        float push = e.mouseStrength * exp(-dist * dist * 60.0);
        acc += normalize(d + 1e-5) * push / float2(e.aspect, 1.0);
    }
    p.vel += acc * e.dt;
    p.vel *= 1.0 - min(e.dt * 0.15, 0.2) * step(0.0001, e.turbulence);
    p.pos += p.vel * e.dt;
    p.angle += p.spin * e.dt;
}

struct ParticleOut {
    float4 position [[position]];
    float2 corner;
    float4 color;
    float shape [[flat]];
};

vertex ParticleOut mp_particle_vertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      const device Particle* ps [[buffer(0)]],
                                      constant Emitter& e [[buffer(1)]],
                                      constant MPLayer& layer [[buffer(2)]]) {
    Particle p = ps[iid];
    float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[vid];
    float t = saturate(p.life / max(p.maxLife, 1e-3));
    float fadeIn = e.fade.x > 0.0 ? saturate(t / e.fade.x) : 1.0;
    float fadeOut = e.fade.y > 0.0 ? saturate((1.0 - t) / e.fade.y) : 1.0;
    float tw = 1.0 - e.twinkle * (0.5 + 0.5 * sin(e.time * (2.0 + p.seed * 5.0) + p.seed * 40.0));
    float4 col = mix(e.color, e.colorEnd, t);
    col.a *= fadeIn * fadeOut * tw;

    float2 offset;
    if (e.shape == 2) {
        float2 dir = normalize(p.vel * float2(e.aspect, 1.0) + 1e-5);
        float len = max(p.size, length(p.vel * float2(e.aspect, 1.0)) * e.stretch);
        float2 along = dir * len;
        float2 across = float2(-dir.y, dir.x) * p.size;
        offset = (along * c.y + across * c.x) / float2(e.aspect, 1.0);
    } else {
        float2 r = mp_rotate(c * float2(p.size), p.angle);
        offset = r / float2(e.aspect, 1.0);
    }
    float2 canvas = p.pos + layer.shift + offset;
    float2 screen = (canvas - layer.region.xy) / layer.region.zw;
    ParticleOut o;
    o.position = float4(screen.x * 2.0 - 1.0, 1.0 - screen.y * 2.0, 0, 1);
    o.corner = c;
    o.color = col * float4(1, 1, 1, layer.opacity);
    o.shape = float(e.shape);
    return o;
}

fragment float4 mp_particle_fragment(ParticleOut in [[stage_in]],
                                     texture2d<float> sprite [[texture(0)]]) {
    float r = length(in.corner);
    float a;
    int shape = int(in.shape);
    if (shape == 0) a = smoothstep(1.0, 0.6, r);
    else if (shape == 1) a = exp(-r * r * 4.0) + 0.6 * smoothstep(0.35, 0.0, r);
    else if (shape == 2) a = smoothstep(1.0, 0.0, abs(in.corner.x)) * smoothstep(1.0, 0.7, abs(in.corner.y));
    else if (shape == 3) a = smoothstep(0.2, 0.0, abs(r - 0.78)) * 0.9 + smoothstep(1.0, 0.0, r) * 0.08;
    else if (shape == 4) {
        float2 q = in.corner * float2(1.6, 1.0);
        float petal = 1.0 - length(q);
        float notch = smoothstep(0.0, 0.25, abs(in.corner.x) + (1.0 - in.corner.y) * 0.25);
        a = smoothstep(0.0, 0.15, petal) * mix(0.6, 1.0, notch);
    } else {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 t = sprite.sample(s, in.corner * 0.5 + 0.5);
        float4 c = in.color * t;
        return float4(c.rgb * c.a, c.a);
    }
    a = saturate(a) * in.color.a;
    return float4(in.color.rgb * a, a);
}
"""#
}
