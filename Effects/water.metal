// Gentle ripples and glints on water, only where the mask is white.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    if (m < 0.01) return in.source.sample(in.linear, px.screen);
    float aspect = mp_aspect(frame);
    float2 p = float2(px.uv.x * aspect, px.uv.y) * params.scale;
    float t = frame.time * params.speed;
    float n1 = mp_fbm(p * float2(1.0, 3.0) + float2(t * 0.6, t * 0.2), 4);
    float n2 = mp_fbm(p * float2(1.3, 4.0) - float2(t * 0.4, -t * 0.3), 4);
    float2 offset = float2(n1 - 0.5, n2 - 0.5) * params.strength * 0.008 * m;
    float3 col = in.source.sample(in.linear, px.screen + offset).rgb;
    float sparkle = mp_noise(px.uv * frame.canvas / 3.0 + float2(t * 9.0, sin(t) * 4.0));
    float glint = smoothstep(0.86, 0.97, sparkle) * smoothstep(0.5, 0.7, n1) * params.glints * m;
    col += glint * (0.35 + mp_luma(col)) * 0.8;
    return float4(col, 1.0);
}
