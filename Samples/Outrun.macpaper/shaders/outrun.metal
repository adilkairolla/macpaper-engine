// An endless synthwave drive: a striped sun over neon ridgelines, and a glowing grid floor rushing toward
// the viewer. Everything is a function of time, so it never repeats a seam.

static float or_ridge(float x, float seed) {
    float h = 0.0, a = 0.5, f = 1.0;
    for (int i = 0; i < 5; i++) {
        h += a * (1.0 - abs(mp_noise(float2(x * f + seed, seed * 3.1)) * 2.0 - 1.0));
        f *= 2.1; a *= 0.5;
    }
    return h;
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float aspect = mp_aspect(frame);
    float2 uv = px.uv;
    float horizon = params.horizon + frame.parallax.y * 0.01;
    float t = frame.time * params.speed;
    float bass = frame.audio[0].x * 0.6 + frame.audio[0].y * 0.4;
    float pulse = 1.0 + bass * params.react;

    float3 col;
    if (uv.y < horizon) {
        // Sky: deep violet to hot magenta at the horizon, with stars.
        float k = uv.y / horizon;
        col = mix(params.skyTop.rgb, params.skyLow.rgb, pow(k, 1.8));
        float2 sg = float2(uv.x * aspect, uv.y) * 140.0;
        float2 sid = floor(sg);
        float sh = mp_hash(sid);
        float star = step(0.985, sh) * smoothstep(0.35, 0.0, length(fract(sg) - 0.5 - (mp_hash2(sid) - 0.5) * 0.5));
        star *= 0.5 + 0.5 * sin(frame.time * (1.0 + sh * 3.0) + sh * 40.0);
        col += star * (1.0 - k) * 0.9;

        // Sun with horizontal cut stripes that scroll down into the horizon.
        float2 sc = float2(0.5 + frame.parallax.x * 0.01, horizon - params.sunSize * 0.62);
        float2 d = (uv - sc) * float2(aspect, 1.0);
        float r = length(d) / (params.sunSize * pulse);
        float3 sunCol = mix(params.sunTop.rgb, params.sunLow.rgb, saturate((uv.y - (sc.y - params.sunSize)) / (params.sunSize * 2.0)));
        // Cut-out bands below the sun's middle that thicken toward the horizon and slide down into it.
        float stripeY = (uv.y - sc.y) / (params.sunSize * pulse);
        float phase = fract(stripeY * 6.0 - frame.time * 0.35);
        float gap = pow(saturate(stripeY * 1.1), 0.8) * 0.7;
        float cut = stripeY < 0.0 ? 1.0 : smoothstep(gap - 0.03, gap + 0.03, phase);
        float disc = smoothstep(1.0, 0.99, r) * cut;
        col = mix(col, sunCol * 1.15, disc);
        col += sunCol * exp(-max(r - 1.0, 0.0) * 4.0) * 0.35 * pulse;

        // Two ridgelines of mountains with neon rims.
        float x = uv.x * aspect + frame.parallax.x * 0.02;
        float edge = smoothstep(0.08, 0.42, abs(uv.x - 0.5));
        float far = horizon - pow(or_ridge(x * 0.75 + 3.0, 1.7), 2.2) * (0.06 + 0.2 * edge);
        float near = horizon - pow(or_ridge(x * 1.2 + 11.0, 5.3), 2.4) * (0.03 + 0.13 * edge);
        if (uv.y > far) {
            float g = (uv.y - far) / max(horizon - far, 1e-3);
            col = mix(params.mountain.rgb * 1.6, params.mountain.rgb * 0.6, g);
            col += params.grid.rgb * exp(-(uv.y - far) * 900.0) * 1.2;
        }
        if (uv.y > near) {
            col = params.mountain.rgb * 0.45;
            col += params.rim.rgb * exp(-(uv.y - near) * 700.0) * 1.4;
        }
    } else {
        // Floor: a perspective grid scrolling toward the viewer.
        float depth = (uv.y - horizon) / (1.0 - horizon);
        float z = 1.0 / max(depth, 1e-3);
        float gx = ((uv.x - 0.5) * aspect - frame.parallax.x * 0.04) * z * params.gridScale;
        float gz = z * params.gridScale * 0.5 + t * 2.2;
        float2 g = 0.5 - abs(fract(float2(gx, gz)) - 0.5);
        float2 w = float2(fwidth(gx), fwidth(gz));
        float2 core = smoothstep(w * 1.5, w * 0.5, g);
        float2 halo = exp(-g / max(w * 6.0, 1e-4));
        float line = max(core.x, core.y);
        float glowLine = max(halo.x, halo.y);
        float fade = smoothstep(0.0, 0.25, depth);
        col = params.floor.rgb * (0.4 + 0.6 * depth);
        col += params.grid.rgb * (line * 1.3 + glowLine * 0.35) * (0.35 + 1.1 * fade) * pulse;
        col += params.skyLow.rgb * exp(-depth * 9.0) * 0.6;
        // The sun reflected on the floor.
        float refl = exp(-pow((uv.x - 0.5) * aspect * 3.0, 2.0)) * exp(-depth * 6.0);
        col += params.sunLow.rgb * refl * 0.5;
    }

    float haze = exp(-abs(uv.y - horizon) * 22.0);
    col += params.skyLow.rgb * haze * 0.45;
    float scan = 0.96 + 0.04 * sin(px.coord.y * 3.14159);
    return float4(col * scan, 1.0);
}
