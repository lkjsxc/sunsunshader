// SPDX-License-Identifier: Apache-2.0
// Original luminance-preserving toe and exponential photographic shoulder.
// The shoulder tends smoothly to display white instead of discarding values
// above one. Colour is retained in shade; only bright highlights lose saturation.
fn post(input: PostInput) -> vec4<f32> {
    let environment = max(frame.eye_light_smooth.x * 0.65, frame.eye_light_smooth.y);
    let adaptation = mix(1.40, 1.0, smoothstep(0.05, 0.90, environment));
    let scene = max(input.color.rgb * exposure * adaptation, vec3<f32>(0.0));
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
    return vec4<f32>(ss_encode(color), 1.0);
}
