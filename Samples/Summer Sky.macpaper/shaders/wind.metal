// Gusts rolling through grass or foliage inside the mask: sideways sway that grows toward the top of each blade
// (lower in the picture sways less) and travels across the field. Periodic in time, so it loops forever.
// params: strength, speed, gust (size of gust waves), anchor (0 = sway evenly, 1 = only tips move)

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    if (m < 0.002) return float4(in.source.sample(in.linear, px.screen).rgb, 1.0);
    float t = frame.time * params.speed;
    float2 p = px.uv * float2(mp_aspect(frame), 1.0);
    float gust = 0.55 + 0.45 * sin(p.x * params.gust - t * 1.3 + mp_noise(p * 2.0 + t * 0.2) * 3.0);
    float flutter = sin(p.x * 140.0 + p.y * 60.0 + t * 7.0) * 0.25 + sin(p.x * 61.0 - t * 4.3) * 0.35;
    // Blades are anchored at the bottom of the masked band: sample the mask a little lower to find how far up we are.
    float below = in.mask.sample(in.linear, px.uv + float2(0.0, 0.02)).r;
    float tip = mix(1.0, saturate(1.0 - below + 0.25), params.anchor);
    float dx = (gust * 0.8 + flutter * 0.2) * params.strength * 0.004 * tip;
    float3 c = in.source.sample(in.linear, px.screen + float2(dx, abs(dx) * 0.3)).rgb;
    c *= 1.0 + gust * 0.06 * params.strength * m;
    float3 base = in.source.sample(in.linear, px.screen).rgb;
    return float4(mix(base, c, m), 1.0);
}
