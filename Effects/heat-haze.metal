// Shimmering air, strongest where the mask is white.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    float t = frame.time * params.speed;
    float2 p = px.uv * float2(mp_aspect(frame), 1.0) * 18.0;
    float n = mp_noise(p + float2(0.0, t * 3.0)) - 0.5;
    float n2 = mp_noise(p * 1.9 - float2(t, t * 4.0)) - 0.5;
    float2 offset = float2(n, n2) * params.strength * 0.006 * m;
    return in.source.sample(in.linear, px.screen + offset);
}
