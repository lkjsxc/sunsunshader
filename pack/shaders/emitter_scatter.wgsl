// SPDX-License-Identifier: Apache-2.0
// Original finite-ray single scattering from visible emissive terrain.
// Integrating 1 / (r^2 + t^2) gives the atan difference below. Beer-Lambert
// extinction attenuates the source-to-medium and medium-to-eye paths.
// This is a screen-space light-source approximation, not hidden-world GI.

fn ss_light_path_visibility(source: vec3<f32>, medium: vec3<f32>) -> f32 {
    let steps = select(2u, 4u, quality >= 2u);
    var visibility = 1.0;
    for (var i = 0u; i < steps; i += 1u) {
        let fraction = (f32(i) + 0.5) / f32(steps);
        let point = mix(source, medium, fraction);
        let clip = frame.projection * frame.view * vec4<f32>(point, 1.0);
        if clip.w <= 0.001 { return 0.0; }
        let uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if any(uv <= vec2<f32>(0.0)) || any(uv >= vec2<f32>(1.0)) { return 0.0; }
        let depth = depth_at(uv);
        if depth > 0.0000001 {
            let obstacle = length(view_position(uv, depth));
            let point_distance = length(point);
            let bias = 0.20 + point_distance * 0.006;
            visibility *= 1.0 - smoothstep(bias, bias + 0.30, point_distance - obstacle);
        }
    }
    return visibility;
}

fn ss_emitter_scatter(source: vec4<f32>, ray: vec3<f32>, distance: f32, uv: vec2<f32>) -> vec3<f32> {
    if source.w <= 0.0 { return vec3<f32>(0.0); }
    let source_uv = ss_emitter_uv(source);
    let screen_delta = abs((source_uv - uv) * frame.resolution);
    // Discovery has finite circular support. Reach zero before its last cell
    // so a source crossing that boundary does not cut a luminous rectangle.
    let support_radius = ss_emitter_support_radius();
    let support = 1.0 - smoothstep(support_radius * (50.0 / 82.0), support_radius, length(screen_delta));
    let screen_edge = min(min(source_uv.x, 1.0 - source_uv.x) * frame.resolution.x,
        min(source_uv.y, 1.0 - source_uv.y) * frame.resolution.y);
    let edge = smoothstep(1.0, 10.0, screen_edge / max(frame.resolution.y / 540.0, 1.0));
    if support * edge <= 0.0001 { return vec3<f32>(0.0); }

    let source_position = ss_emitter_position(source);
    let projected = dot(source_position, ray);
    let closest = clamp(projected, 0.0, distance);
    let medium = ray * closest;
    let separation = source_position - medium;
    let separation_squared = dot(separation, separation);
    let reach = 8.0 + 5.0 * frame.rain + 2.0 * clamp(frame.downfall, 0.0, 1.0);
    let range_weight = 1.0 - smoothstep(reach * 0.60, reach, sqrt(separation_squared));
    if range_weight <= 0.0001 { return vec3<f32>(0.0); }

    let density = ss_local_air_density();
    let perpendicular = source_position - ray * projected;
    let radius = sqrt(dot(perpendicular, perpendicular) + 0.32 * 0.32);
    let integral = max((atan((distance - projected) / radius) + atan(projected / radius)) / radius, 0.0);
    let transmission = exp(-density * (closest + sqrt(separation_squared)));
    let visibility = ss_light_path_visibility(source_position, medium);
    let source_surface = surface_at(ss_emitter_pixel(source));
    let source_color = ss_metadata_source_colour(source_surface.data);
    // Emission level supplies source power. A dark decorative texel on the
    // same emitting block must not imprint a hard brightness band in its air.
    let drift = ss_periodic_drift(vec2<f32>(0.018, 0.009));
    let world_medium = medium + frame.camera_position;
    let texture_density = 0.84 + 0.32 * ss_noise3(world_medium * 0.24 + vec3<f32>(drift.x, 0.0, drift.y));
    let strength = ss_emitter_strength(source);
    return source_color * (integral * density * transmission * visibility * strength
        * range_weight * support * edge * texture_density * 8.0);
}

fn post(input: PostInput) -> vec4<f32> {
    let distance = select(max(frame.render_distance, 64.0),
        length(view_position(input.uv, max(input.depth, 0.0000001))), input.depth > 0.0000001);
    if !local_haze || quality == 0u || ss_local_air_density() < 0.00001 {
        return vec4<f32>(vec3<f32>(0.0), distance);
    }
    let size = vec2<i32>(textureDimensions(ss_bloom));
    let center = clamp(vec2<i32>(input.uv * vec2<f32>(size)), vec2<i32>(0), size - 1);
    let ray = ss_emitter_ray(input.uv);
    var candidates: array<vec4<f32>, 3>;
    var scores: array<f32, 3>;
    var cells: array<vec3<i32>, 3>;
    let count = select(2u, 3u, quality >= 2u);
    for (var y = -1i; y <= 1i; y += 1i) {
        for (var x = -1i; x <= 1i; x += 1i) {
            let texel = center + vec2<i32>(x, y);
            if any(texel < vec2<i32>(0)) || any(texel >= size) { continue; }
            let source = textureLoad(ss_bloom, texel, 0);
            if source.w <= 0.0 { continue; }
            let position = ss_emitter_position(source);
            let cell = vec3<i32>(floor(position + frame.camera_position + normalize(position) * 0.02));
            let score = ss_emitter_rank(source, ray);
            var chosen = 0u;
            for (var i = 0u; i < count; i += 1u) {
                if candidates[i].w > 0.0 && all(cells[i] == cell) {
                    chosen = i; break;
                }
                if scores[i] < scores[chosen] { chosen = i; }
            }
            if score > scores[chosen] {
                candidates[chosen] = source; scores[chosen] = score; cells[chosen] = cell;
            }
        }
    }
    var scattering = vec3<f32>(0.0);
    for (var i = 0u; i < count; i += 1u) {
        scattering += ss_emitter_scatter(candidates[i], ray, distance, input.uv);
    }
    return vec4<f32>(scattering, distance);
}
