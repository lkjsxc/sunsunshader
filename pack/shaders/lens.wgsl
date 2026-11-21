// SPDX-License-Identifier: Apache-2.0
// Original edge-aware spatial resolve. No jitter or object-motion guide is
// exposed by this engine revision, so history is deliberately not accumulated.

fn ss_lens_read(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(previous, linear_sampler, clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0)), 0.0).rgb;
}

fn ss_lens_pair(uv: vec2<f32>, axis: vec2<f32>) -> vec3<f32> {
    return (ss_lens_read(uv - axis * 0.4) + ss_lens_read(uv + axis * 0.4)) * 0.5;
}

fn ss_edge_resolve(uv: vec2<f32>, center: vec3<f32>) -> vec3<f32> {
    let texel = 1.0 / frame.resolution;
    var color = center;
    if quality > 0u {
        let north = ss_lens_read(uv - vec2<f32>(0.0, texel.y));
        let south = ss_lens_read(uv + vec2<f32>(0.0, texel.y));
        let west = ss_lens_read(uv - vec2<f32>(texel.x, 0.0));
        let east = ss_lens_read(uv + vec2<f32>(texel.x, 0.0));
        let vertical = abs(dot(north - south, vec3<f32>(0.2126, 0.7152, 0.0722)));
        let horizontal = abs(dot(west - east, vec3<f32>(0.2126, 0.7152, 0.0722)));
        let luma = dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
        let neighbour_luma = vec4<f32>(dot(north, vec3<f32>(0.2126, 0.7152, 0.0722)), dot(south, vec3<f32>(0.2126, 0.7152, 0.0722)),
            dot(west, vec3<f32>(0.2126, 0.7152, 0.0722)), dot(east, vec3<f32>(0.2126, 0.7152, 0.0722)));
        let minimum = min(luma, min(min(neighbour_luma.x, neighbour_luma.y), min(neighbour_luma.z, neighbour_luma.w)));
        let maximum = max(luma, max(max(neighbour_luma.x, neighbour_luma.y), max(neighbour_luma.z, neighbour_luma.w)));
        let contrast = (maximum - minimum) / (0.04 + maximum);
        let band = 0.1 * (horizontal + vertical) + 0.02 * maximum + 0.0001;
        let axis_mix = smoothstep(-band, band, horizontal - vertical);
        let axis_x = vec2<f32>(texel.x, 0.0);
        let axis_y = vec2<f32>(0.0, texel.y);
        var filtered: vec3<f32>;
        if axis_mix <= 0.0 {
            filtered = ss_lens_pair(uv, axis_y);
        } else if axis_mix >= 1.0 {
            filtered = ss_lens_pair(uv, axis_x);
        } else {
            filtered = mix(ss_lens_pair(uv, axis_y), ss_lens_pair(uv, axis_x), axis_mix);
        }
        color = mix(color, filtered, smoothstep(0.18, 0.85, contrast) * 0.65);
    }

    if vignette {
        let radial = length((uv - vec2<f32>(0.5)) * vec2<f32>(1.15, 1.0));
        color *= 1.0 - smoothstep(0.25, 0.72, radial) * 0.16;
    }
    return max(color, vec3<f32>(0.0));
}
