// Soft glow around bright highlights.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float3 base = in.source.sample(in.linear, px.screen).rgb;
    float2 texel = params.radius * 0.004 * float2(frame.resolution.y / frame.resolution.x, 1.0);
    float3 glow = float3(0.0);
    float total = 0.0;
    for (int r = 1; r <= 3; r++) {
        for (int i = 0; i < 8; i++) {
            float a = float(i) * 0.785398 + float(r) * 0.4;
            float2 o = float2(cos(a), sin(a)) * texel * float(r);
            float3 c = in.source.sample(in.linear, px.screen + o).rgb;
            float w = 1.0 / float(r);
            glow += max(c - params.threshold, 0.0) * w;
            total += w;
        }
    }
    glow /= total;
    return float4(base + glow * params.intensity * 4.0, 1.0);
}
