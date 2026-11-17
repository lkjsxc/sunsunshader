// SPDX-License-Identifier: Apache-2.0
// Photographic compression: Reinhard et al., "Photographic Tone Reproduction
// for Digital Images" (2002). This shoulder and gamut treatment are original.

fn post(input: PostInput) -> vec4<f32> {
    // Horizon eases this light over two seconds, avoiding brightness steps.
    let environment = max(frame.eye_light_smooth.x * 0.65, frame.eye_light_smooth.y);
    let adaptation = mix(1.24, 1.0, smoothstep(0.05, 0.90, environment));
    let scene = max(input.color.rgb * exposure * adaptation, vec3<f32>(0.0));
    let luma = dot(scene, vec3<f32>(0.2126, 0.7152, 0.0722));
    let ceiling = 1.0;
    let compressed = luma / (1.0 + luma / ceiling);
    var color = scene * (compressed / max(luma, 0.00001));
    // Ease very bright colours toward a neutral highlight before gamut clipping.
    let highlight = smoothstep(0.7 * ceiling, 2.5 * ceiling, luma) * 0.24;
    color = mix(color, vec3<f32>(compressed), highlight);
    let peak_channel = max(max(color.r, color.g), color.b);
    if peak_channel > ceiling {
        color *= ceiling / peak_channel;
    }
    return vec4<f32>(ss_encode(color), 1.0);
}
