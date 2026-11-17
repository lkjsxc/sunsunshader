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
    let shoulder = smoothstep(0.48, 2.6, luma) * 0.50;
    color = mix(color, vec3<f32>(mapped), shoulder);
    let peak = max(color.r, max(color.g, color.b));
    if peak > 1.0 {
        let excess = (peak - 1.0) / max(peak - mapped, 0.00001);
        color = mix(color, vec3<f32>(mapped), clamp(excess, 0.0, 1.0));
    }
    return vec4<f32>(ss_encode(color), 1.0);
}
