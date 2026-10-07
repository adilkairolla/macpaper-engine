// A calm sea at sunset: sky gradient, sun with glow, perspective waves and a glittering sun path.
static float wave_height(float2 p, float t) {
    float h = 0.0;
    float a = 0.5;
    float2 d = float2(1.0, 0.25);
    for (int i = 0; i < 5; i++) {
        h += a * sin(dot(p, d) + t * (1.0 + float(i) * 0.35));
        d = mp_rotate(d, 1.1) * 1.85;
        a *= 0.5;
    }
    return h + (mp_fbm(p * 0.6 + t * 0.05, 3) - 0.5) * 0.6;
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float aspect = mp_aspect(frame);
    float2 uv = px.uv;
    float horizon = params.horizon;
    float2 sun = params.sun;
    float t = frame.time * params.speed;
    float3 col;
    if (uv.y < horizon) {
        float h = saturate((horizon - uv.y) / horizon);
        col = mix(params.low.rgb, params.high.rgb, pow(h, 0.6));
        float d = length((uv - sun) * float2(aspect, 1.0));
        col += params.sunColor.rgb * (exp(-d * 9.0) * 0.6 + exp(-d * 40.0) * 0.6);
        col = mix(col, float3(1.0, 0.97, 0.9), smoothstep(0.035, 0.03, d));
        float clouds = mp_fbm(float2(uv.x * aspect * 1.4 + t * 0.01, uv.y * 7.0), 5);
        float band = smoothstep(horizon * 0.25, horizon * 0.85, uv.y) * smoothstep(horizon, horizon * 0.8, uv.y);
        col = mix(col, params.low.rgb * 0.55 + params.sunColor.rgb * 0.25, smoothstep(0.55, 0.75, clouds) * band * 0.8);
    } else {
        float depth = (uv.y - horizon) / (1.0 - horizon);
        float z = 1.0 / max(depth, 0.004);
        float2 p = float2((uv.x - sun.x) * aspect * z * 2.0, z * 3.0) * params.scale;
        float e = 0.05;
        float h0 = wave_height(p, t);
        float hx = wave_height(p + float2(e, 0.0), t);
        float hz = wave_height(p + float2(0.0, e), t);
        float3 n = normalize(float3(-(hx - h0) / e * params.waves, 1.0, -(hz - h0) / e * params.waves * 2.0));
        float fres = pow(1.0 - saturate(n.y * 0.9), 3.0);
        float3 sky = mix(params.low.rgb, params.high.rgb, 0.3);
        float3 water = mix(params.deep.rgb, sky, 0.25 + fres * 0.6);
        float sunX = (uv.x - sun.x) * aspect;
        float path = exp(-abs(sunX) * (6.0 + depth * 10.0) / max(depth, 0.08));
        float glitter = smoothstep(0.55, 0.95, n.x * 0.5 + n.z * 0.5 + 0.5) * path;
        water += params.sunColor.rgb * (path * 0.35 + glitter * 1.6);
        float haze = exp(-depth * 6.0);
        col = mix(water, params.low.rgb, haze * 0.7);
    }
    return float4(col, 1.0);
}
