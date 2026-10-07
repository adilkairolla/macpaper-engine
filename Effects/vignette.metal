// Darkened edges that pull the eye to the centre.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float2 d = px.screen - 0.5;
    d.x *= frame.resolution.x / frame.resolution.y;
    float v = smoothstep(params.radius, params.radius - params.softness, length(d));
    return float4(params.color.rgb, (1.0 - v) * params.amount);
}
