// Night sky gradient that brightens slightly toward the horizon.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float3 col = mix(params.top.rgb, params.horizon.rgb, pow(px.uv.y, 1.6));
    col += (mp_hash(px.coord) - 0.5) * 0.012;
    return float4(col, 1.0);
}
