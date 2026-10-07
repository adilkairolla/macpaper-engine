// Pulses the scene's highlights with the bass of whatever is playing.
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float3 c = in.source.sample(in.linear, px.screen).rgb;
    float bass = (frame.audio[0].x + frame.audio[0].y + frame.audio[0].z) / 3.0;
    float pulse = smoothstep(0.2, 0.9, bass) * params.intensity;
    float hi = smoothstep(0.5, 1.0, mp_luma(c));
    return float4(c + params.color.rgb * hi * pulse + c * pulse * 0.08, 1.0);
}
