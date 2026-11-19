// SPDX-License-Identifier: Apache-2.0
// Original luminance-preserving toe and exponential photographic shoulder.
// The shoulder tends smoothly to display white instead of discarding values
// above one. Colour is retained in shade; only bright highlights lose saturation.
fn post(input: PostInput) -> vec4<f32> {
    // Only the player brightness control lifts faint, already lit detail.
    // Multiplication keeps a zero-radiance room exactly black at every setting.
    let input_luma = dot(max(input.color.rgb, vec3<f32>(0.0)), vec3<f32>(0.2126, 0.7152, 0.0722));
    let player_gain = 1.0 + 0.25 * frame.brightness * (1.0 - smoothstep(0.002, 0.06, input_luma));
    let scene = max(input.color.rgb * exposure * player_gain, vec3<f32>(0.0));
    let luma = dot(scene, vec3<f32>(0.2126, 0.7152, 0.0722));
    let toe = luma * (luma + 0.045) / (luma + 0.060);
    let mapped = 1.0 - exp(-toe * 1.55);
    var color = scene * (mapped / max(luma, 0.00001));
    // Roll the brightest channel smoothly inside the display gamut. Fitting
    // a saturated emitter toward display white erases its orange/red identity.
    // The small neutral shoulder allows hot cores without whitening whole lava.
    let shoulder = smoothstep(0.65, 3.5, luma) * 0.08;
    color = mix(color, vec3<f32>(mapped), shoulder);
    let peak = max(color.r, max(color.g, color.b));
    let over = max(peak - 0.78, 0.0);
    let peak_mapped = min(peak, 0.78) + 0.22 * (1.0 - exp(-over / 0.22));
    color *= peak_mapped / max(peak, 0.00001);
    return vec4<f32>(ss_world_bound(color), 1.0);
}
