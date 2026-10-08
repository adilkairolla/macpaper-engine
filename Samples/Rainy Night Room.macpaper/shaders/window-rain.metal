// Rain on a window pane, only where the mask is white: drops slide down leaving clear wet trails through the
// misted glass, small beads come and go, and each drop is a tiny lens showing a flipped view of what's behind it.
// params: amount, speed, size, blur (how misted the dry glass is), streaks (rain falling outside)

static float3 rg_hash3(float n) {
    float3 p = fract(float3(n) * float3(0.1031, 0.1137, 0.1379));
    p += dot(p, p.yzx + 19.19);
    return fract((p.xxy + p.yzz) * p.zyx);
}

/// A drop: x = coverage 0…1, yz = position inside it relative to its radius (−1…1).
static float3 rg_drop(float2 d, float r) {
    float2 n = d / r;
    float cover = smoothstep(1.0, 0.82, length(n));
    return float3(cover, n);
}

/// One layer of sliding drops in `q` space (canvas-height units, y down). w: wet trail left behind.
static float4 rg_sliding(float2 q, float t, float size) {
    float2 cell = float2(0.09, 0.42) * size;
    float2 id = floor(q / cell);
    float2 local = q / cell - id;
    float3 r = rg_hash3(id.x * 71.3 + id.y * 113.9);
    if (r.y < 0.35) return float4(0.0);
    float progress = fract(t * (0.07 + 0.08 * r.y) + r.z);
    float fall = progress * progress * (3.0 - 2.0 * progress);
    float y = mix(0.1, 0.92, fall);
    float x = 0.5 + (r.x - 0.5) * 0.5 + sin(local.y * 15.0 + r.z * 40.0) * 0.03;
    float2 d = (local - float2(x, y)) * cell;
    float radius = cell.x * (0.09 + 0.06 * r.x);
    float3 drop = rg_drop(d * float2(1.0, 0.8), radius);
    float above = smoothstep(0.0, 0.03, y - local.y) * smoothstep(0.0, 0.35, local.y);
    float trail = smoothstep(radius * 0.55, radius * 0.25, abs(d.x)) * above;
    return float4(drop, trail);
}

static float3 rg_beads(float2 q, float t, float size) {
    float2 g = q * 34.0 / size;
    float2 id = floor(g);
    float3 r = rg_hash3(id.x * 17.1 + id.y * 931.7);
    if (r.y < 0.45) return float3(0.0);
    float life = fract(t * 0.03 + r.z);
    float grow = smoothstep(0.0, 0.08, life) * smoothstep(1.0, 0.75, life);
    float2 d = (fract(g) - 0.5 - (r.xy - 0.5) * 0.5) / 34.0 * size;
    float radius = (0.06 + 0.1 * fract(r.z * 7.0)) / 34.0 * size * grow;
    return radius > 1e-5 ? rg_drop(d, radius) : float3(0.0);
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    float3 behind = in.source.sample(in.linear, px.screen).rgb;
    if (m < 0.002) return float4(behind, 1.0);
    float aspect = mp_aspect(frame);
    float2 q = float2(px.uv.x * aspect, px.uv.y);
    float t = frame.time * params.speed;

    float4 a = rg_sliding(q, t, params.size);
    float4 b = rg_sliding(q * 1.45 + float2(3.7, 1.3), t * 1.15, params.size);
    float3 c = rg_beads(q, t, params.size);
    float3 drop = a.x >= b.x ? a.xyz : b.xyz;
    if (c.x > drop.x) drop = c;
    drop.x *= smoothstep(0.0, 0.4, params.amount);
    float trail = max(a.w, b.w) * saturate(params.amount * 2.0);

    float3 misted = float3(0.0);
    float radius = params.blur * 0.012;
    for (int ring = 1; ring <= 2; ring++) {
        for (int i = 0; i < 8; i++) {
            float ang = (float(i) + float(ring) * 0.5) * 0.785398;
            misted += in.source.sample(in.linear, px.screen + float2(cos(ang) / aspect, sin(ang)) * radius * float(ring) * 0.5).rgb;
        }
    }
    misted = mix(misted / 16.0, float3(mp_luma(misted / 16.0)), 0.15) * 0.9 + 0.035;
    float3 col = mix(misted, behind, trail);

    // A water drop acts like a small fish-eye lens: the view behind is flipped and pulled in from around it.
    float2 lens = -drop.yz * (0.035 * params.size) / float2(aspect, 1.0);
    float3 refracted = in.source.sample(in.linear, px.screen + lens).rgb * 1.06;
    float rim = smoothstep(0.55, 1.0, length(drop.yz));
    refracted *= 1.0 - rim * 0.35;
    float spec = smoothstep(0.35, 0.0, length(drop.yz - float2(-0.3, -0.38)));
    refracted += spec * 0.25;
    col = mix(col, refracted, drop.x);

    float2 rr = float2(q.x * 90.0 + q.y * 10.0, q.y * 1.6 - frame.time * params.speed * 2.6);
    float lane = mp_hash(float2(floor(rr.x), 3.0));
    float len = 0.08 + 0.12 * fract(lane * 13.7);
    float streak = smoothstep(1.0 - len, 1.0, fract(rr.y + lane * 7.0)) * step(0.6, lane);
    float thin = exp(-pow((fract(rr.x) - 0.5) * 7.0, 2.0));
    col += streak * thin * params.streaks * 0.35 * (0.4 + mp_luma(behind)) * (1.0 - drop.x);

    return float4(mix(behind, col, m), 1.0);
}
