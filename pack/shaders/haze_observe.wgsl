// SPDX-License-Identifier: Apache-2.0
// Every native pixel discovers emission. Receiver sampling alone is bounded
// to one/four deterministic observations per at-most-480x270 stratum lattice.
fn ss_haze_accum_key(base: u32, key: vec3<i32>) -> bool {
    return atomicLoad(&ss_light_accum[base]) == bitcast<u32>(key.x)
        && atomicLoad(&ss_light_accum[base + 1u]) == bitcast<u32>(key.y)
        && atomicLoad(&ss_light_accum[base + 2u]) == bitcast<u32>(key.z);
}

fn compute(input: ComputeInput) {
    if !input.in_bounds { return; }
    if !local_haze || quality == 0u || ss_local_air_density() < 0.00001 { return; }
    if atomicLoad(&ss_light_accum[0u]) != SS_HAZE_MAGIC
        || atomicLoad(&ss_light_accum[2u]) != frame.world_epoch
        || atomicLoad(&ss_light_accum[3u]) != frame.frame_index
        || atomicLoad(&ss_light_accum[14u]) != SS_HAZE_HEADER_OK { return; }
    let dimensions = vec2<u32>(atomicLoad(&ss_light_accum[8u]), atomicLoad(&ss_light_accum[9u]));
    if any(input.size.xy != dimensions) || input.cell.z != 0u
        || any(textureDimensions(scene_depth) != dimensions) { return; }
    let camera = ss_haze_camera();
    if !camera.valid { return; }
    let pixel = vec2<i32>(input.cell.xy);
    let surface = surface_at(pixel);
    let receiver = ss_haze_decode_receiver(surface.smoothness, surface.present);
    if !receiver.valid { return; }
    let depth = textureLoad(scene_depth, pixel, 0);
    if !(depth > 0.0000001) { return; }
    let uv = (vec2<f32>(input.cell.xy) + vec2<f32>(0.5)) / vec2<f32>(dimensions);
    let position = view_position(uv, depth);
    if !ss_haze_local_position_valid(position) { return; }
    let colour = clamp(ss_metadata_source_colour(surface.data), vec3<f32>(0.0), vec3<f32>(1.0));
    let level = u32(round(clamp(ss_metadata_emission(surface.data), 0.0, 1.0) * 15.0));
    if level > 0u && ss_haze_e_witness_unambiguous(position, surface.normal, camera) {
        let key = ss_haze_e_key(position, surface.normal, receiver.inward, camera);
        if ss_haze_active_e(key, camera) {
            let base = ss_haze_e_accum(key);
            if ss_haze_accum_key(base, key) {
                let q = atomicLoad(&ss_light_accum[11u]);
                let witness_offset = position - ss_haze_e_relative(key, vec3<f32>(0.0), camera);
                let geometry_ok = all(witness_offset >= vec3<f32>(-1.0 / 512.0))
                    && all(witness_offset <= vec3<f32>(1.0 + 1.0 / 512.0));
                let face = 1u << ss_haze_face(surface.normal);
                atomicAdd(&ss_light_accum[base + 3u], 1u);
                atomicAdd(&ss_light_accum[base + 4u], ss_haze_quantize(q, colour.r));
                atomicAdd(&ss_light_accum[base + 5u], ss_haze_quantize(q, colour.g));
                atomicAdd(&ss_light_accum[base + 6u], ss_haze_quantize(q, colour.b));
                atomicMin(&ss_light_accum[base + 7u], level);
                atomicMax(&ss_light_accum[base + 8u], level);
                atomicMin(&ss_light_accum[base + 9u], input.cell.y * dimensions.x + input.cell.x);
                atomicOr(&ss_light_accum[base + 10u], face | select(SS_HAZE_E_BAD_GEOMETRY, 0u, geometry_ok));
            }
        }
    }
    let multiple = atomicLoad(&ss_light_accum[12u]) == 4u;
    if !ss_haze_axis_sample(input.cell.x, dimensions.x, 480u, multiple)
        || !ss_haze_axis_sample(input.cell.y, dimensions.y, 270u, multiple) { return; }
    let first = ss_haze_r_lower(position, camera);
    let first_position = ss_haze_r_relative(first, camera);
    let fraction = clamp((position - first_position) * 0.5, vec3<f32>(0.0), vec3<f32>(1.0));
    let q = atomicLoad(&ss_light_accum[13u]);
    let evidence = select(SS_HAZE_HAS_ZERO, SS_HAZE_HAS_POSITIVE, receiver.positive)
        | select(0u, SS_HAZE_HAS_STRONG, receiver.strong) | (1u << (8u + ss_haze_face(surface.normal)));
    for (var child = 0u; child < 8u; child += 1u) {
        let corner = ss_haze_child(child);
        let key = first + corner;
        if !ss_haze_active_r(key, camera) { continue; }
        let base = ss_haze_r_accum(key);
        if !ss_haze_accum_key(base, key) { continue; }
        let weight = ss_haze_splat_weight(fraction, corner);
        let quantized_weight = ss_haze_quantize(q, weight);
        if quantized_weight == 0u { continue; }
        let offset = position - ss_haze_r_relative(key, camera);
        let centroid = clamp((offset + vec3<f32>(2.0)) * 0.25, vec3<f32>(0.0), vec3<f32>(1.0));
        atomicAdd(&ss_light_accum[base + 3u], quantized_weight);
        atomicAdd(&ss_light_accum[base + 4u], ss_haze_quantize(q, weight * receiver.block));
        atomicAdd(&ss_light_accum[base + 5u], ss_haze_quantize(q, weight * colour.r));
        atomicAdd(&ss_light_accum[base + 6u], ss_haze_quantize(q, weight * colour.g));
        atomicAdd(&ss_light_accum[base + 7u], ss_haze_quantize(q, weight * colour.b));
        atomicAdd(&ss_light_accum[base + 8u], ss_haze_quantize(q, weight * centroid.x));
        atomicAdd(&ss_light_accum[base + 9u], ss_haze_quantize(q, weight * centroid.y));
        atomicAdd(&ss_light_accum[base + 10u], ss_haze_quantize(q, weight * centroid.z));
        atomicOr(&ss_light_accum[base + 11u], evidence);
    }
}
