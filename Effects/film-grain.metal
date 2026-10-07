// Fine animated film grain.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float3 base = in.source.sample(in.linear, px.screen).rgb;
    float2 cell = floor(px.coord / max(params.size, 1.0));
    float n = mp_hash(cell + fract(frame.time * 24.0) * 97.0) - 0.5;
    float l = mp_luma(base);
    float weight = 1.0 - abs(l - 0.5) * 1.2;
    return float4(base + n * params.amount * 0.25 * weight, 1.0);
}
