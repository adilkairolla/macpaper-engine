// Flowing silk: domain-warped noise shaded like folded fabric. Pulses with music when audio-reactive is on.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float2 p = float2(px.uv.x * mp_aspect(frame), px.uv.y) * params.scale;
    float t = frame.time * params.speed * 0.08;
    float2 q = float2(mp_fbm(p + float2(0.0, t), 5), mp_fbm(p + float2(5.2, 1.3 - t), 5));
    float2 r = float2(mp_fbm(p + 3.0 * q + float2(1.7, 9.2) + t * 0.6, 5), mp_fbm(p + 3.0 * q + float2(8.3, 2.8) - t * 0.4, 5));
    float f = mp_fbm(p + 3.5 * r, 5);
    float folds = sin(f * 14.0 + r.x * 6.0) * 0.5 + 0.5;
    float3 col = mix(params.a.rgb, params.b.rgb, saturate(f * 1.4));
    col = mix(col, params.c.rgb, saturate(length(q) * 0.9 - 0.2));
    col *= 0.65 + 0.55 * pow(folds, 1.5);
    float sheen = pow(folds, 18.0) * (0.35 + frame.audioLevel * params.pulse * 1.5);
    col += sheen * mix(params.c.rgb, float3(1.0), 0.6);
    float2 v = px.screen - 0.5;
    col *= 1.0 - dot(v, v) * 0.8;
    return float4(col, 1.0);
}
