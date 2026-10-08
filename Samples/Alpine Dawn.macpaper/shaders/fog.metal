// Low rolling fog that thickens toward the bottom of the frame.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float band = smoothstep(params.height - 0.35, params.height + 0.25, px.uv.y);
    if (band <= 0.0) return float4(0.0);
    float2 p = float2(px.uv.x * mp_aspect(frame), px.uv.y) * 2.2;
    float t = frame.time * params.speed;
    float n = mp_fbm(p + float2(t * 0.08, 0.0), 5);
    float n2 = mp_fbm(p * 2.1 - float2(t * 0.05, t * 0.01), 4);
    float density = saturate((n * 0.7 + n2 * 0.5 - 0.35) * 2.0) * band * params.density;
    return float4(params.color.rgb, density);
}
