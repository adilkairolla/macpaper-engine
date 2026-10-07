// Curtains of aurora rippling over the sky.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float2 uv = px.uv;
    float t = frame.time * params.speed;
    float aspect = mp_aspect(frame);
    if (uv.y > params.height + 0.4) return float4(0.0);
    float3 acc = float3(0.0);
    float alpha = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float x = uv.x * aspect * (0.8 + fi * 0.3) + fi * 3.7;
        float wave = mp_fbm(float2(x * 0.5 + t * 0.04, fi * 2.0 + t * 0.015), 4);
        float base = params.height + (wave - 0.5) * 0.3 + fi * 0.05;
        float d = uv.y - base;
        float below = exp(-max(d, 0.0) * 22.0);
        float above = smoothstep(-0.28, 0.0, d) * (0.4 + 0.6 * smoothstep(-0.28, -0.05, d));
        float folds = 0.75 + 0.25 * mp_noise(float2(x * 9.0 + wave * 6.0, t * 0.3 + fi));
        float a = below * above * folds * (0.55 - fi * 0.12);
        float3 c = mix(params.colorA.rgb, params.colorB.rgb, saturate(-d * 4.0 + 0.2 * fi));
        acc += c * a;
        alpha += a;
    }
    float glow = saturate(alpha * params.intensity);
    return float4(acc / max(alpha, 1e-3), glow);
}
