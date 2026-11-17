// SPDX-License-Identifier: Apache-2.0
// Original edge-aware spatial resolve. No jitter or object-motion guide is
// exposed by this engine revision, so history is deliberately not accumulated.

fn ss_lens_read(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(previous, linear_sampler, clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0)), 0.0).rgb;
}

fn post(input: PostInput) -> vec4<f32> {
    let texel = 1.0 / frame.resolution;
    var color = input.color.rgb;
    if quality > 0u {
        let north = ss_lens_read(input.uv - vec2<f32>(0.0, texel.y));
        let south = ss_lens_read(input.uv + vec2<f32>(0.0, texel.y));
        let west = ss_lens_read(input.uv - vec2<f32>(texel.x, 0.0));
        let east = ss_lens_read(input.uv + vec2<f32>(texel.x, 0.0));
        let vertical = abs(dot(north - south, frame.luminance));
        let horizontal = abs(dot(west - east, frame.luminance));
        let luma = dot(color, frame.luminance);
        let neighbour_luma = vec4<f32>(dot(north, frame.luminance), dot(south, frame.luminance),
            dot(west, frame.luminance), dot(east, frame.luminance));
        let minimum = min(luma, min(min(neighbour_luma.x, neighbour_luma.y), min(neighbour_luma.z, neighbour_luma.w)));
        let maximum = max(luma, max(max(neighbour_luma.x, neighbour_luma.y), max(neighbour_luma.z, neighbour_luma.w)));
        let contrast = (maximum - minimum) / (0.04 + maximum);
        let across = select(vec2<f32>(0.0, texel.y), vec2<f32>(texel.x, 0.0), horizontal > vertical);
        let filtered = (ss_lens_read(input.uv - across * 0.4)
            + ss_lens_read(input.uv + across * 0.4)) * 0.5;
        color = mix(color, filtered, smoothstep(0.18, 0.85, contrast) * 0.65);
    }

    if vignette {
        let radial = length((input.uv - vec2<f32>(0.5)) * vec2<f32>(1.15, 1.0));
        color *= 1.0 - smoothstep(0.25, 0.72, radial) * 0.16;
    }
    return vec4<f32>(max(color, vec3<f32>(0.0)), 1.0);
}
