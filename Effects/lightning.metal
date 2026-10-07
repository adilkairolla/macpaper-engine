// Distant storm flashes lighting up the masked sky.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    float period = max(0.5, 10.0 / max(params.frequency, 0.05));
    float cycle = floor(frame.time / period);
    float local = frame.time - cycle * period;
    float start = mp_hash(float2(cycle, 3.0)) * (period - 1.0);
    float k = local - start;
    float flash = 0.0;
    if (k > 0.0 && k < 0.6) {
        flash = exp(-k * 9.0) + 0.6 * exp(-abs(k - 0.18) * 30.0) + 0.4 * exp(-abs(k - 0.32) * 40.0);
    }
    float2 c = float2(mp_hash(float2(cycle, 7.0)), 0.15);
    float spread = 1.0 - smoothstep(0.0, 0.9, distance(px.uv, c));
    return float4(params.color.rgb, saturate(flash * params.intensity * m * (0.4 + spread)));
}
