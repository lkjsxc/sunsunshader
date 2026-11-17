// Copyright 2026 Sunsun Shader contributors. SPDX-License-Identifier: Apache-2.0
// Original implementation of blocker search and variable-width filtering:
// Randima Fernando, "Percentage-Closer Soft Shadows", SIGGRAPH 2005.
// Distances come from the supplied orthographic transform, not a guessed near plane.

fn ss_shadow_depth_scale() -> f32 {
    return max(length(vec3<f32>(
        frame.shadow_view_proj[0].z,
        frame.shadow_view_proj[1].z,
        frame.shadow_view_proj[2].z
    )), 0.00001);
}

fn ss_shadow_edge(p: vec3<f32>) -> f32 {
    if p.z <= 0.0 || p.z >= 1.0 {
        return 0.0;
    }
    let edge = max(abs(p.x * 2.0 - 1.0), abs(p.y * 2.0 - 1.0));
    return 1.0 - smoothstep(0.82, 0.99, edge);
}

fn ss_shadow_disk(index: u32, count: u32) -> vec2<f32> {
    let radius = sqrt((f32(index) + 0.5) / f32(count));
    let angle = f32(index) * 2.39996323 + 0.37;
    return vec2<f32>(cos(angle), sin(angle)) * radius;
}

fn ss_shadow_visibility(position: vec3<f32>) -> f32 {
    let cloud = ss_cloud_transmittance(position);
    if !shadows || frame.has_shadow == 0u {
        return cloud;
    }
    let bias = max(frame.shadow_center_texel * 0.24, 0.012);
    let p = shadow_position(position + frame.light_direction * bias);
    let edge = ss_shadow_edge(p);
    if edge <= 0.0 {
        return cloud;
    }
    let lit = textureSampleCompareLevel(shadow_map, shadow_sampler, p.xy, p.z);
    return mix(1.0, lit, edge) * cloud;
}

fn ss_shadow(position: vec3<f32>, normal: vec3<f32>) -> vec3<f32> {
    let cloud = ss_cloud_transmittance(position);
    if !shadows || frame.has_shadow == 0u {
        return vec3<f32>(cloud);
    }

    let facing = clamp(dot(normal, frame.light_direction), 0.0, 1.0);
    let bias = max(frame.shadow_center_texel * (0.20 + 0.55 * (1.0 - facing)), 0.012);
    let shifted = position + normal * bias + frame.light_direction * bias * 0.35;
    let p = shadow_position(shifted);
    let edge = ss_shadow_edge(p);
    if edge <= 0.0 {
        return vec3<f32>(cloud);
    }

    let side = max(frame.shadow_resolution, 1.0);
    let texel = 1.0 / side;
    var radius = texel * 0.65;
    var count = 4u;
    if quality >= 1u {
        count = 8u;
        if quality >= 2u { count = 12u; }
        if quality >= 3u { count = 16u; }

        let search_radius = texel * select(3.0, 5.0, quality >= 2u);
        var blockers = 0.0;
        var blocker_sum = 0.0;
        for (var i = 0u; i < count; i += 1u) {
            let uv = p.xy + ss_shadow_disk(i, count) * search_radius;
            let pixel = clamp(vec2<i32>(uv * side), vec2<i32>(0), vec2<i32>(i32(side) - 1));
            let depth = textureLoad(shadow_map, pixel, 0);
            if depth < p.z && depth < 0.99999 {
                blockers += 1.0;
                blocker_sum += depth;
            }
        }
        if blockers > 0.0 {
            let separation = max(p.z - blocker_sum / blockers, 0.0) / ss_shadow_depth_scale();
            let dx = shadow_position(shifted + vec3<f32>(1.0, 0.0, 0.0)).xy - p.xy;
            let dy = shadow_position(shifted + vec3<f32>(0.0, 1.0, 0.0)).xy - p.xy;
            let dz = shadow_position(shifted + vec3<f32>(0.0, 0.0, 1.0)).xy - p.xy;
            let uv_per_block = max(length(dx), max(length(dy), length(dz)));
            // A finite solar disc: separation broadens the penumbra.
            radius = clamp(uv_per_block * separation * 0.0093 + texel * 0.6, texel * 0.6, texel * 10.0);
        }
    }

    var opaque_visibility = 0.0;
    var clear_visibility = 0.0;
    for (var i = 0u; i < count; i += 1u) {
        let uv = p.xy + ss_shadow_disk(i, count) * radius;
        opaque_visibility += textureSampleCompareLevel(shadow_map, shadow_sampler, uv, p.z);
        clear_visibility += textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, uv, p.z);
    }
    opaque_visibility /= f32(count);
    clear_visibility /= f32(count);

    let pixel = clamp(vec2<i32>(p.xy * side), vec2<i32>(0), vec2<i32>(i32(side) - 1));
    let filter_color = ss_decode_light(textureLoad(shadow_color, pixel, 0));
    var transmission = mix(vec3<f32>(1.0), clamp(filter_color.rgb, vec3<f32>(0.02), vec3<f32>(1.0)),
                           min(filter_color.a, 0.9));
    if filter_color.a > 0.995 {
        let water_depth = textureLoad(shadow_map_translucent, pixel, 0);
        let path = clamp((p.z - water_depth) / ss_shadow_depth_scale(), 0.0, 32.0);
        transmission = exp(-vec3<f32>(0.18, 0.055, 0.022) * path);
    }
    let filtered = opaque_visibility * mix(transmission, vec3<f32>(1.0), clear_visibility);
    return mix(vec3<f32>(1.0), filtered, edge) * cloud;
}
