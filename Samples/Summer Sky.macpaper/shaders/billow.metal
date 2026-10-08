// Clouds that slowly churn in place: the picture inside the mask is pushed around by a smooth, ever-changing
// noise field. Nothing is cross-faded, so shapes never ghost; the mask's soft edge pins the skyline in place.
// params: amount (largest push, canvas heights), scale (billows per canvas height), speed

static float bl_hash(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

static float bl_noise(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(bl_hash(i), bl_hash(i + float3(1, 0, 0)), u.x),
                   mix(bl_hash(i + float3(0, 1, 0)), bl_hash(i + float3(1, 1, 0)), u.x), u.y),
               mix(mix(bl_hash(i + float3(0, 0, 1)), bl_hash(i + float3(1, 0, 1)), u.x),
                   mix(bl_hash(i + float3(0, 1, 1)), bl_hash(i + float3(1, 1, 1)), u.x), u.y), u.z);
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    if (m < 0.002) return in.source.sample(in.linear, px.screen);
    float aspect = mp_aspect(frame);
    float3 q = float3(px.uv * float2(aspect, 1.0) * params.scale, frame.time * params.speed * 0.04);
    float2 push = float2(bl_noise(q), bl_noise(q + float3(19.1, 7.3, 3.7))) - 0.5;
    push += (float2(bl_noise(q * 2.07 + 5.0), bl_noise(q * 2.07 + 11.0)) - 0.5) * 0.5;
    float2 o = push * params.amount * m / float2(aspect, 1.0);
    return float4(in.source.sample(in.linear, px.screen + o).rgb, 1.0);
}
