// Volumetric light streaming from a point, carried by the bright parts of the scene.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float2 origin = params.origin;
    float2 delta = (px.uv - origin) * params.length / 32.0;
    float2 screenDelta = delta * float2(1.0, 1.0);
    float2 s = px.screen;
    float illum = 0.0;
    float decay = 1.0;
    for (int i = 0; i < 32; i++) {
        s -= screenDelta;
        float3 c = in.source.sample(in.linear, s).rgb;
        illum += smoothstep(params.threshold, 1.0, mp_luma(c)) * decay;
        decay *= 0.96;
    }
    illum /= 32.0;
    float shimmer = 0.85 + 0.15 * mp_noise(float2(atan2(px.uv.y - origin.y, px.uv.x - origin.x) * 8.0, frame.time * 0.3));
    float3 base = in.source.sample(in.linear, px.screen).rgb;
    float3 col = base + params.color.rgb * illum * params.intensity * shimmer * 1.6;
    return float4(col, 1.0);
}
