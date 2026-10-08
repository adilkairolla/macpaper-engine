// Makes the picture's own lights come alive inside the mask: bright pixels flicker (lanterns, city windows) or
// twinkle (stars). Dark pixels are left alone.
// params: amount, speed, cell (size of a region that flickers together, in canvas heights), threshold, glow,
//         tint, blink (some lights switching off), points (1 = only pinpoints brighter than their surroundings,
//         e.g. stars; broad bright areas stay still)

static float tw_hash(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

// Value noise over space and time, so every region flickers in place with no seams between regions.
static float tw_noise(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(tw_hash(i), tw_hash(i + float3(1, 0, 0)), u.x),
                   mix(tw_hash(i + float3(0, 1, 0)), tw_hash(i + float3(1, 1, 0)), u.x), u.y),
               mix(mix(tw_hash(i + float3(0, 0, 1)), tw_hash(i + float3(1, 0, 1)), u.x),
                   mix(tw_hash(i + float3(0, 1, 1)), tw_hash(i + float3(1, 1, 1)), u.x), u.y), u.z);
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    float3 c = in.source.sample(in.linear, px.screen).rgb;
    if (m < 0.002) return float4(c, 1.0);
    float aspect = mp_aspect(frame);
    float lum = mp_luma(c);

    float lit = smoothstep(params.threshold, params.threshold + 0.25, lum);
    if (params.points > 0.0) {
        float r = max(params.cell, 0.002) * 0.6;
        float around = 0.0;
        for (int i = 0; i < 8; i++) {
            float a = float(i) * 0.785398;
            around += mp_luma(in.source.sample(in.linear, px.screen + float2(cos(a) / aspect, sin(a)) * r).rgb);
        }
        float point = smoothstep(0.03, 0.14, lum - around / 8.0) * step(params.threshold * 0.6, lum);
        lit = mix(lit, point, params.points);
    }
    if (lit < 0.001) return float4(c, 1.0);

    float3 q = float3(px.uv * float2(aspect, 1.0) / max(params.cell, 1e-4), frame.time * params.speed);
    float flick = tw_noise(q * float3(1.0, 1.0, 2.2)) * 0.65 + tw_noise(q * float3(1.0, 1.0, 6.5) + 17.0) * 0.35;
    float k = 1.0 + (flick - 0.5) * 2.0 * params.amount;
    float off = smoothstep(0.62, 0.72, tw_noise(float3(q.xy, q.z * 0.25) + 41.0));
    k *= 1.0 - off * params.blink;

    float3 lightCol = c * k + c * max(k - 1.0, 0.0) * params.glow * params.tint.rgb;
    return float4(mix(c, lightCol, lit * m), 1.0);
}
