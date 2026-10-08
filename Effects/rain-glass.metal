// Raindrops on a window: drops slide down leaving wet trails, small beads come and go,
// and the scene behind refracts through them while the dry glass stays misted.
static float3 rg_hash3(float n) {
    float3 p = fract(float3(n) * float3(0.1031, 0.1137, 0.1379));
    p += dot(p, p.yzx + 19.19);
    return fract((p.xxy + p.yzz) * p.zyx);
}

static float rg_bump(float2 d, float r) {
    float k = dot(d, d) / (r * r);
    return k < 1.0 ? sqrt(1.0 - k) : 0.0;
}

/// One layer of sliding drops in `q` space (canvas-height units, y down). x: height, y: trail wetness.
static float2 rg_sliding(float2 q, float t, float size) {
    float2 cell = float2(0.11, 0.5) * size;
    float2 id = floor(q / cell);
    float2 local = q / cell - id;
    float3 r = rg_hash3(id.x * 71.3 + id.y * 113.9);
    float progress = fract(t * (0.12 + 0.12 * r.y) + r.z);
    float fall = progress * progress * (3.0 - 2.0 * progress);
    float y = mix(0.12, 0.92, fall);
    float x = 0.5 + (r.x - 0.5) * 0.55 + sin(local.y * 17.0 + r.z * 40.0) * 0.04;
    float2 d = (local - float2(x, y)) * cell / cell.x;
    float radius = 0.16 * (0.75 + 0.5 * r.y);
    float h = rg_bump(d * float2(1.0, 0.85), radius);
    float above = smoothstep(0.0, 0.02, y - local.y);
    float width = radius * 0.35 * smoothstep(0.0, y, local.y);
    float trail = smoothstep(width, 0.0, abs(d.x)) * above * smoothstep(0.0, 0.3, local.y);
    float bead = fract(local.y * 9.0 + r.x * 3.0);
    float2 bd = float2(d.x, (bead - 0.5) * cell.y / cell.x / 9.0);
    h += rg_bump(bd, radius * 0.3) * trail * step(0.5, r.x);
    return float2(h, trail);
}

static float rg_beads(float2 q, float t, float size) {
    float2 g = q * 28.0 / size;
    float2 id = floor(g);
    float3 r = rg_hash3(id.x * 17.1 + id.y * 931.7);
    float2 p = (r.xy - 0.5) * 0.6;
    float life = fract(t * 0.05 + r.z);
    float fade = smoothstep(0.0, 0.05, life) * smoothstep(1.0, 0.6, life);
    return rg_bump(fract(g) - 0.5 - p, 0.12 + 0.18 * fract(r.z * 7.0)) * fade * step(0.35, r.y);
}

static float2 rg_field(float2 q, float t, float amount, float size) {
    float2 a = rg_sliding(q, t, size);
    float2 b = rg_sliding(q * 1.6 + float2(3.7, 1.3), t * 1.1, size);
    float beads = rg_beads(q, t, size) * smoothstep(0.0, 0.4, amount);
    float h = beads + a.x * smoothstep(0.2, 0.7, amount) + b.x * smoothstep(0.0, 0.5, amount);
    return float2(h, max(a.y, b.y) * amount);
}

float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float2 q = float2(px.uv.x * mp_aspect(frame), px.uv.y);
    float t = frame.time * params.speed;
    float e = 0.0015;
    float2 c = rg_field(q, t, params.amount, params.size);
    float hx = rg_field(q + float2(e, 0.0), t, params.amount, params.size).x;
    float hy = rg_field(q + float2(0.0, e), t, params.amount, params.size).x;
    float2 normal = float2(hx - c.x, hy - c.x) / e;
    // The bump is steep at a drop's rim; capping the slope keeps refraction to a small, flipped view
    // of what's behind the drop instead of a sample from across the screen.
    normal *= min(1.0, 60.0 / max(length(normal), 1e-4));
    float2 screen = px.screen - normal * 0.0009;
    float3 sharp = in.source.sample(in.linear, screen).rgb;
    float3 misted = float3(0.0);
    float radius = params.blur * 0.004;
    for (int i = 0; i < 12; i++) {
        float a = float(i) * 0.5236;
        float ring = (i % 2 == 0) ? 1.0 : 0.55;
        misted += in.source.sample(in.linear, px.screen + float2(cos(a), sin(a)) * radius * ring).rgb;
    }
    misted = misted / 12.0 * 0.92 + 0.04;
    float clear = saturate(c.x * 3.0 + c.y * 0.9);
    float3 col = mix(misted, sharp, clear);
    col += pow(saturate(dot(normalize(float3(-normal, 1.0)), normalize(float3(0.4, -0.6, 0.7)))), 30.0) * c.x * 0.35;
    return float4(col, 1.0);
}
