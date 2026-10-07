// Layered mountain ridges in silhouette, rim-lit by the aurora.
static float ridge(float x, float seed, float height, float rough) {
    float n = mp_fbm(float2(x * rough + seed, seed * 3.1), 5);
    float peaks = 1.0 - abs(mp_noise(float2(x * rough * 1.3 + seed * 7.0, seed)) * 2.0 - 1.0);
    return height - (n - 0.35) * 0.45 - peaks * peaks * 0.12;
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float x = px.uv.x * mp_aspect(frame);
    float y = px.uv.y;
    // Ridges never rise more than ~0.35 above their base height, so the sky above costs nothing.
    if (y < params.height - 0.4) return float4(0.0);
    float4 out = float4(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float top = ridge(x, 4.0 + fi * 11.0, params.height + fi * 0.08, 1.4 + fi * 0.7);
        if (y > top) {
            float shade = mix(0.55, 0.12, fi / 2.0) * (1.0 - smoothstep(0.0, 0.35, y - top) * 0.5);
            float3 c = params.color.rgb * shade + params.rim.rgb * smoothstep(0.006, 0.0, y - top) * (0.35 - fi * 0.1);
            float fog = exp(-(y - top) * 6.0) * (0.3 - fi * 0.08);
            out = float4(mix(c, params.rim.rgb * 0.4, fog), 1.0);
        }
    }
    return out;
}
