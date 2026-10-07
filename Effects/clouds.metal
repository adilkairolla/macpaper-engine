// Clouds drifting across the sky, limited to the masked area.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    float2 p = float2(px.uv.x * mp_aspect(frame), px.uv.y * 2.5) * params.scale;
    float t = frame.time * params.speed * 0.02;
    float shape = (mp_fbm(p + float2(t, 0.0), 6) - 0.5) * 2.4 + 0.5;
    float detail = mp_fbm(p * 3.0 + float2(t * 1.6, t * 0.3), 4);
    float v = shape + (detail - 0.5) * 0.4;
    float c = smoothstep(1.0 - params.coverage, 1.0 - params.coverage + params.softness, v);
    float shade = mix(0.72, 1.0, smoothstep(0.3, 0.8, detail));
    return float4(params.color.rgb * shade, c * m * params.opacity);
}
