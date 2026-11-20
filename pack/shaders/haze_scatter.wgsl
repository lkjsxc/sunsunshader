// SPDX-License-Identifier: Apache-2.0
// Receiver AIR retains its quadrature and independent light gate. The compact
// emitter halo also reaches geometry behind its source, with conservative depth
// reconstruction. Discovery, source identity and the SKY kernel are unchanged.
fn ss_haze_scatter_header(camera: SsHazeCamera) -> bool {
    let header = ss_world_light[0u];
    let origin = ss_world_light[1u];
    return camera.valid && header.x == SS_HAZE_MAGIC && header.y == SS_HAZE_SCHEMA
        && header.z == frame.world_epoch && header.w == frame.frame_index
        && ss_haze_key_equal(origin.xyz, camera.origin) && origin.w == 32u
        && ss_world_light[3u].z == SS_HAZE_HEADER_OK;
}

fn ss_haze_sample_field(point: vec3<f32>, camera: SsHazeCamera) -> vec3<f32> {
    // Continuous camera-centred support, separate from source-cell taper.
    // For |point|_infinity <28, all trilinear corners are inside the snapped
    // storage cube: last positive node is30-phase>28, negative bound<=-32.
    let range = ss_haze_range(point);
    if range <= 0.0 { return vec3<f32>(0.0); }
    let first = ss_haze_r_lower(point, camera);
    let fraction = clamp((point - ss_haze_r_relative(first, camera)) * 0.5,
        vec3<f32>(0.0), vec3<f32>(1.0));
    var colour = vec3<f32>(0.0);
    for (var child = 0u; child < 8u; child += 1u) {
        let corner = ss_haze_child(child);
        let key = first + corner;
        // Derived records have no individual key: the current header and
        // this full active-window test must precede every modulo address.
        if !ss_haze_active_r(key, camera) { return vec3<f32>(0.0); }
        let value = ss_world_light[SS_HAZE_B_AIR + ss_haze_r_index(key)];
        let weight = ss_haze_splat_weight(fraction, corner);
        colour += bitcast<vec3<f32>>(value.xyz) * weight;
    }
    // Missing evidence contributes no modeled light. It is not labeled a
    // native zero, and interpolation is never renormalized across unknowns.
    return colour * range;
}

// SKY only: unknown offscreen path samples are neutral. Known on-screen depth
// keeps rc4's exact occlusion product. This is not unseen-world visibility.
fn ss_haze_sky_path_visibility(source: vec3<f32>, medium: vec3<f32>, eye: vec3<f32>) -> f32 {
    let steps = select(2u, 4u, quality >= 2u);
    var visibility = 1.0;
    for (var i = 0u; i < steps; i += 1u) {
        let fraction = (f32(i) + 0.5) / f32(steps);
        let point = mix(source, medium, fraction);
        let clip = frame.projection * frame.view * vec4<f32>(point, 1.0);
        if clip.w <= 0.001 { return 0.0; }
        let uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if any(uv <= vec2<f32>(0.0)) || any(uv >= vec2<f32>(1.0)) { continue; }
        let depth = depth_at(uv);
        if depth > 0.0000001 {
            let obstacle = length(view_position(uv, depth) - eye);
            let point_distance = length(point - eye);
            let bias = 0.20 + point_distance * 0.006;
            visibility *= 1.0 - smoothstep(bias, bias + 0.30, point_distance - obstacle);
        }
    }
    return visibility;
}

fn ss_haze_sky_emitter(key: vec3<i32>, camera: SsHazeCamera, eye: vec3<f32>, ray: vec3<f32>,
    distance: f32, uv: vec2<f32>, density: f32, geometry: bool, receiver_view_depth: f32) -> vec4<f32> {
    if !ss_haze_active_e(key, camera) { return vec4<f32>(0.0); }
    let base = ss_haze_e_record(key);
    let identity = ss_world_light[base];
    let evidence = ss_world_light[base + 3u];
    if !ss_haze_key_equal(identity.xyz, key) || evidence.z != frame.world_epoch
        || (identity.w & SS_HAZE_STATE_MASK) != SS_HAZE_LIVE { return vec4<f32>(0.0); }
    let light = bitcast<vec4<f32>>(ss_world_light[base + 1u]);
    let witness = bitcast<vec4<f32>>(ss_world_light[base + 2u]);
    let freshness = ss_haze_fresh(witness.w);
    if freshness <= 0.0 || !(light.x > 0.0 && light.x <= 15.0) { return vec4<f32>(0.0); }

    // Fixed block center, never the view-dependent selected surface witness.
    let source_position = ss_haze_e_relative(key, vec3<f32>(0.5), camera);
    let camera_distance = length(source_position);
    if camera_distance >= SS_HAZE_SKY_CAMERA_OUTER { return vec4<f32>(0.0); }
    let camera_weight = 1.0 - smoothstep(SS_HAZE_SKY_CAMERA_INNER,
        SS_HAZE_SKY_CAMERA_OUTER, camera_distance);
    let clip = frame.projection * frame.view * vec4<f32>(source_position, 1.0);
    if clip.w <= 0.001 { return vec4<f32>(0.0); }
    let source_view_depth = -(frame.view * vec4<f32>(source_position, 1.0)).z;
    var geometry_weight = 1.0;
    if geometry {
        let bias = max(0.02, source_view_depth / 512.0);
        geometry_weight = smoothstep(source_view_depth + bias,
            source_view_depth + bias + 0.25, receiver_view_depth);
        if geometry_weight <= 0.0 { return vec4<f32>(0.0); }
    }
    // No source UV clamp or viewport-edge fade: remembered offscreen anchors
    // still contribute wherever their approved circular footprint overlaps.
    let source_uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    let screen_delta = abs((source_uv - uv) * frame.resolution);
    let scale = frame.resolution.y / 1080.0;
    let support_x = length(screen_delta) / (220.0 * scale);
    if support_x >= 1.0 { return vec4<f32>(0.0); }
    let support_u = 1.0 - support_x;
    let support = support_u * support_u * support_u * support_u * (1.0 + 4.0 * support_x);

    // Exact rc4 finite [0,distance] softened inverse-square kernel. No E-distance
    // C1 transfer, 7-block sphere clipping, or smoothed SKY volume is applied.
    let source_offset = source_position - eye;
    let projected = dot(source_offset, ray);
    let closest = clamp(projected, 0.0, distance);
    let ray_offset = ray * closest;
    let medium = eye + ray_offset;
    let separation = source_offset - ray_offset;
    let separation_squared = dot(separation, separation);
    let reach = 8.0 + 5.0 * frame.rain + 2.0 * clamp(frame.downfall, 0.0, 1.0);
    let range_weight = 1.0 - smoothstep(reach * 0.60, reach, sqrt(separation_squared));
    if range_weight <= 0.0001 { return vec4<f32>(0.0); }
    let perpendicular = source_offset - ray * projected;
    let radius = sqrt(dot(perpendicular, perpendicular) + 0.32 * 0.32);
    let integral = max((atan((distance - projected) / radius) + atan(projected / radius)) / radius, 0.0);
    let transmission = exp(-density * (closest + sqrt(separation_squared)));
    let visibility = ss_haze_sky_path_visibility(source_position, medium, eye);
    let source_color = light.yzw;
    let drift = ss_periodic_drift(vec2<f32>(0.018, 0.009));
    let world_medium = medium + frame.camera_position;
    let texture_density = 0.84 + 0.32 * ss_noise3(world_medium * 0.24 + vec3<f32>(drift.x, 0.0, drift.y));
    let strength = light.x / 15.0;
    let kernel = source_color * (integral * density * transmission * visibility * strength
        * range_weight * support * texture_density * 19.2);
    // This Euclidean 16->24 fade replaces the old SKY source-window taper.
    return vec4<f32>(kernel * (freshness * camera_weight * geometry_weight), source_view_depth);
}

fn ss_haze_sky_mask_current(mask: vec4<u32>) -> bool {
    return mask.y == frame.world_epoch && mask.z == frame.frame_index && mask.w == SS_HAZE_SCHEMA;
}

fn ss_haze_sky_sum(camera: SsHazeCamera, eye: vec3<f32>, ray: vec3<f32>, distance: f32,
    uv: vec2<f32>, density: f32, geometry: bool, receiver_view_depth: f32) -> vec4<f32> {
    var scattering = vec3<f32>(0.0);
    var farthest_source = 0.0;
    // Fixed absolute toroidal slot order is stable while the camera window
    // slides. Every eligible macrocell and every child is visited once.
    for (var top_index = 0u; top_index < SS_HAZE_SKY_TOP_COUNT; top_index += 1u) {
        let top = ss_world_light[SS_HAZE_B_SKY_TOP + top_index];
        if !ss_haze_sky_mask_current(top) { return vec4<f32>(0.0); }
        if top.x == 0u { continue; }
        for (var leaf_bit = 0u; leaf_bit < 32u; leaf_bit += 1u) {
            if (top.x & (1u << leaf_bit)) == 0u { continue; }
            let leaf_index = top_index * 32u + leaf_bit;
            let leaf = ss_world_light[SS_HAZE_B_SKY_LEAF + leaf_index];
            if !ss_haze_sky_mask_current(leaf) { return vec4<f32>(0.0); }
            for (var receiver_bit = 0u; receiver_bit < 32u; receiver_bit += 1u) {
                if (leaf.x & (1u << receiver_bit)) == 0u { continue; }
                let key = ss_haze_r_slot_key(leaf_index * 32u + receiver_bit, camera);
                if !ss_haze_active_r(key, camera) { continue; }
                let base = ss_haze_r_record(key);
                let identity = ss_world_light[base];
                let evidence = ss_world_light[base + 3u];
                if !ss_haze_key_equal(identity.xyz, key) || evidence.y != frame.world_epoch { continue; }
                // Child validity is independent of the receiver's own LIVE state.
                let children = (identity.w >> 8u) & 255u;
                for (var child = 0u; child < 8u; child += 1u) {
                    if (children & (1u << child)) == 0u { continue; }
                    let emitter_key = key * vec3<i32>(2) + ss_haze_child(child);
                    let contribution = ss_haze_sky_emitter(emitter_key, camera, eye, ray,
                        distance, uv, density, geometry, receiver_view_depth);
                    scattering += contribution.rgb;
                    if any(contribution.rgb > vec3<f32>(0.0)) {
                        farthest_source = max(farthest_source, contribution.a);
                    }
                }
            }
        }
    }
    return vec4<f32>(scattering, farthest_source);
}

fn compute(input: ComputeInput) {
    let dimensions = textureDimensions(ss_haze);
    if !input.in_bounds || input.cell.z != 0u || any(input.cell.xy >= dimensions) { return; }
    let pixel = vec2<i32>(input.cell.xy);
    let uv = (vec2<f32>(input.cell.xy) + vec2<f32>(0.5)) / vec2<f32>(dimensions);
    let depth = depth_at(uv);
    let endpoint = view_position(uv, max(depth, 0.0000001));
    let distance = select(max(frame.render_distance, 64.0), length(endpoint), depth > 0.0000001);
    // Translated view bob makes the near-plane ray differ from the actual
    // endpoint direction. Gate against the reconstructed surface itself.
    let receiver_view_depth = -(frame.view * vec4<f32>(endpoint, 1.0)).z;
    // Kept targets must be overwritten even when haze is disabled or invalid.
    textureStore(ss_haze, pixel, vec4<f32>(vec3<f32>(0.0), distance));
    textureStore(ss_emitter_halo, pixel, vec4<f32>(0.0));
    let density = ss_local_air_density();
    if !local_haze || quality == 0u || density < 0.00001 { return; }
    let camera = ss_haze_camera();
    if !ss_haze_scatter_header(camera) { return; }
    // Horizon puts view bob in the projection. The perspective center
    // projects to x = y = w = 0, so unproject the clip-space z basis.
    let center = frame.projection_inverse[2];
    let eye = (frame.view_inverse * vec4<f32>(center.xyz / center.w, 0.0)).xyz;
    let near_point = view_position(uv, 0.5);
    let halo_ray = normalize(near_point - eye);
    if depth <= 0.0000001 {
        let sky = ss_haze_sky_sum(camera, eye, halo_ray, distance, uv, density, false, receiver_view_depth);
        textureStore(ss_haze, pixel, vec4<f32>(sky.rgb, distance));
        return;
    }
    let ray = normalize(near_point);
    let exit_distance = SS_HAZE_RANGE_OUTER / max(abs(ray.x), max(abs(ray.y), abs(ray.z)));
    let end = min(distance, exit_distance);
    let count = select(32u, 48u, quality >= 2u);
    let step = end / f32(count);
    let drift = ss_periodic_drift(vec2<f32>(0.018, 0.009));
    var scattering = vec3<f32>(0.0);
    for (var i = 0u; i < count; i += 1u) {
        let along = (f32(i) + 0.5) * step;
        let point = ray * along;
        let incident = ss_haze_sample_field(point, camera);
        let world = point + frame.camera_position;
        let texture_density = 0.84 + 0.32 * ss_noise3(world * 0.24 + vec3<f32>(drift.x, 0.0, drift.y));
        scattering += incident * (density * exp(-density * along) * texture_density * step * SS_HAZE_GAIN);
    }
    textureStore(ss_haze, pixel, vec4<f32>(scattering, distance));
    let halo_distance = length(endpoint - eye);
    textureStore(ss_emitter_halo, pixel,
        ss_haze_sky_sum(camera, eye, halo_ray, halo_distance, uv, density, true, receiver_view_depth));
}
