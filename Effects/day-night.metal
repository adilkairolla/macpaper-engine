// Follows the clock: cooler and darker at night, warm at dawn and dusk.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float3 c = in.source.sample(in.linear, px.screen).rgb;
    float night = 1.0 - frame.daylight;
    float dusk = smoothstep(0.0, 0.5, frame.daylight) * smoothstep(1.0, 0.5, frame.daylight);
    float3 nightCol = mix(float3(mp_luma(c)), c, 0.55) * float3(0.55, 0.65, 0.95) * 0.75;
    float3 duskCol = c * float3(1.12, 0.96, 0.82);
    float3 outc = mix(c, nightCol, night * params.strength);
    outc = mix(outc, duskCol, dusk * params.strength);
    return float4(outc, 1.0);
}
