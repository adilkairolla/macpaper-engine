// Wisps of steam rising from a point (a cup, a kettle), curling as they climb and fading out.
// params: origin (canvas uv), width, height (canvas heights), speed, opacity, color

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float2 d = (px.uv - params.origin) * float2(mp_aspect(frame), 1.0);
    float up = -d.y / max(params.height, 1e-3);
    if (up < -0.05 || up > 1.0 || abs(d.x) > params.width * 3.0) return float4(0.0);
    float t = frame.time * params.speed;
    float sway = sin(up * 5.0 - t * 1.3) * 0.35 + (mp_noise(float2(up * 3.0 - t * 0.8, 2.0)) - 0.5) * 0.9;
    float x = d.x / params.width - sway * up * 1.2;
    float plume = exp(-x * x * (2.5 - 1.6 * up));
    float wisps = mp_fbm(float2(x * 1.5, up * 3.0 - t * 1.6), 5);
    float density = plume * smoothstep(0.35, 0.75, wisps) * smoothstep(-0.05, 0.12, up) * smoothstep(1.0, 0.35, up);
    return float4(params.color.rgb, saturate(density * params.opacity));
}
