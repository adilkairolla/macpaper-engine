// A Schwarzschild black hole (event horizon at r = 1) seen through its own lensing: rays are bent step by
// step, the accretion disk is sampled wherever a ray crosses its plane, and whatever escapes shows the sky.

static float3 bh_hash3(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

static float bh_noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = bh_hash3(i).x, n100 = bh_hash3(i + float3(1, 0, 0)).x;
    float n010 = bh_hash3(i + float3(0, 1, 0)).x, n110 = bh_hash3(i + float3(1, 1, 0)).x;
    float n001 = bh_hash3(i + float3(0, 0, 1)).x, n101 = bh_hash3(i + float3(1, 0, 1)).x;
    float n011 = bh_hash3(i + float3(0, 1, 1)).x, n111 = bh_hash3(i + float3(1, 1, 1)).x;
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

static float bh_fbm3(float3 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * bh_noise3(p); p = p * 2.07 + 11.3; a *= 0.5; }
    return v;
}

/// Stars and a faint galactic band on the celestial sphere.
static float3 bh_sky(float3 d, float3 tint) {
    float3 col = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float scale = 90.0 + 110.0 * float(i);
        float3 p = d * scale;
        float3 id = floor(p);
        float3 h = bh_hash3(id + float(i) * 17.0);
        if (h.x > 0.965) {
            float3 c = id + 0.25 + 0.5 * bh_hash3(id * 1.7);
            float dist = length(p - c);
            float b = pow(saturate(1.0 - dist * 2.2), 6.0) * (h.y * 1.6 + 0.2);
            col += b * mix(float3(1.0, 0.82, 0.62), float3(0.66, 0.78, 1.0), h.z);
        }
    }
    float band = exp(-pow((d.y + 0.25 * d.x) * 2.6, 2.0));
    float dust = bh_fbm3(d * 3.5);
    col += band * (0.02 + 0.05 * dust) * mix(float3(0.55, 0.6, 0.75), tint, 0.25);
    return col;
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float aspect = mp_aspect(frame);
    float2 sp = (px.uv - 0.5) * float2(aspect, 1.0);
    sp.y = -sp.y;

    float t = frame.time;
    float yaw = 0.35 + frame.parallax.x * 0.12;
    float pitch = params.tilt + frame.parallax.y * 0.05;
    float dist = params.distance;
    float3 cam = dist * float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
    float3 fw = normalize(-cam);
    float3 rt = normalize(cross(float3(0.0, 1.0, 0.0), fw));
    float3 up = cross(fw, rt);
    float3 dir = normalize(fw * 1.55 + rt * sp.x + up * sp.y);

    float3 pos = cam;
    float h2 = length_squared(cross(pos, dir));
    float3 col = float3(0.0);
    float alpha = 0.0;
    float glow = 0.0;
    bool captured = false;

    for (int i = 0; i < 110; i++) {
        float r = length(pos);
        if (r < 1.0) { captured = true; break; }
        if (r > dist * 1.6 && dot(pos, dir) > 0.0) break;
        float dt = clamp(0.085 * r, 0.025, 1.4);
        float3 prev = pos;
        dir += -1.5 * h2 * pos / pow(r, 5.0) * dt;
        pos += dir * dt;
        glow += exp(-max(r - 1.5, 0.0) * 6.0) * dt * 0.06;

        // Disk crossing: the ray passed through the equatorial plane between `prev` and `pos`.
        if (prev.y * pos.y < 0.0 && alpha < 0.99) {
            float3 hit = mix(prev, pos, prev.y / (prev.y - pos.y));
            float rr = length(hit.xz);
            float inner = params.inner, outer = params.outer;
            if (rr > inner && rr < outer) {
                float omega = params.spin / pow(rr, 1.5);
                float ang = t * omega;
                float2 rot = float2(hit.x * cos(ang) - hit.z * sin(ang), hit.x * sin(ang) + hit.z * cos(ang));
                float streaks = bh_fbm3(float3(rot * 1.3, rr * 0.5));
                float lanes = bh_fbm3(float3(rr * 2.6 + streaks * 2.2, rot * 0.35));
                float fil = smoothstep(0.32, 0.78, lanes) * (0.45 + 0.8 * streaks);
                float body = smoothstep(inner, inner + 0.35, rr) * smoothstep(outer, outer - 3.0, rr);

                float heat = saturate((outer - rr) / (outer - inner));
                float3 base = mix(params.cool.rgb, params.hot.rgb, pow(heat, 1.6));
                base = mix(base, float3(1.0, 0.97, 0.92), pow(heat, 5.0) * 0.8);

                // Doppler beaming: the side orbiting toward the camera is brighter and bluer.
                float3 orbit = normalize(float3(-hit.z, 0.0, hit.x));
                float toward = dot(orbit, -normalize(dir));
                float beam = pow(1.0 + 0.45 * toward, 3.0);
                float3 c = base * beam * (0.35 + 2.2 * pow(heat, 2.4)) * (0.3 + 0.9 * fil) * params.brightness;

                // Optically thick: the filaments shade the disk but never let the far side show through it.
                float a = saturate(body * 1.6);
                col += (1.0 - alpha) * c * a;
                alpha += (1.0 - alpha) * a;
            }
        }
    }

    float3 sky = captured ? float3(0.0) : bh_sky(normalize(dir), params.cool.rgb);
    col += (1.0 - alpha) * sky;
    if (!captured) col += (1.0 - alpha) * glow * params.hot.rgb * 0.9;

    // Filmic curve: highlights roll off instead of clipping, so the disk stays hot white without banding.
    col = 1.0 - exp(-col * params.exposure);
    col = pow(col, float3(0.95));
    float vig = smoothstep(1.25, 0.35, length(sp));
    return float4(col * mix(0.75, 1.0, vig), 1.0);
}
