// SPDX-License-Identifier: Apache-2.0
// Reads only completed observation records; writes only the disjoint derived
// ranges. Receiver air remains inferred; the SKY region is now an emitter directory.

// Preserve the approved rc4 screen-depth path guard. Offscreen path samples
// return zero; caching source positions does not remove this visibility limit.
fn ss_haze_path_visibility(source: vec3<f32>, medium: vec3<f32>) -> f32 {
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

fn ss_haze_air_header(camera: SsHazeCamera) -> bool {
    let header = ss_world_light[0u];
    let origin = ss_world_light[1u];
    return camera.valid && header.x == SS_HAZE_MAGIC && header.y == SS_HAZE_SCHEMA
        && header.z == frame.world_epoch && header.w == frame.frame_index
        && ss_haze_key_equal(origin.xyz, camera.origin) && origin.w == 32u
        && ss_world_light[3u].z == SS_HAZE_HEADER_OK;
}


// Each mask is recomputed from immutable completed receiver headers, never from
// a mask another invocation is writing. Receiver LIVE is not an emitter gate.
fn ss_haze_sky_leaf_bits(leaf: u32, camera: SsHazeCamera) -> u32 {
    var bits = 0u;
    for (var bit = 0u; bit < 32u; bit += 1u) {
        let key = ss_haze_r_slot_key(leaf * 32u + bit, camera);
        if !ss_haze_active_r(key, camera) { continue; }
        let base = ss_haze_r_record(key);
        let identity = ss_world_light[base];
        let evidence = ss_world_light[base + 3u];
        if !ss_haze_key_equal(identity.xyz, key) || evidence.y != frame.world_epoch { continue; }
        if ((identity.w >> 8u) & 255u) != 0u { bits |= 1u << bit; }
    }
    return bits;
}

fn ss_haze_write_sky_directory(owner: u32, camera: SsHazeCamera, enabled: bool) {
    if owner < SS_HAZE_SKY_LEAF_COUNT {
        var bits = 0u;
        if enabled { bits = ss_haze_sky_leaf_bits(owner, camera); }
        ss_world_light[SS_HAZE_B_SKY_LEAF + owner] =
            vec4<u32>(bits, frame.world_epoch, frame.frame_index, SS_HAZE_SCHEMA);
    }
    if owner < SS_HAZE_SKY_TOP_COUNT {
        var bits = 0u;
        if enabled {
            for (var bit = 0u; bit < 32u; bit += 1u) {
                // Deliberate independent recomputation avoids a global barrier.
                if ss_haze_sky_leaf_bits(owner * 32u + bit, camera) != 0u {
                    bits |= 1u << bit;
                }
            }
        }
        ss_world_light[SS_HAZE_B_SKY_TOP + owner] =
            vec4<u32>(bits, frame.world_epoch, frame.frame_index, SS_HAZE_SCHEMA);
    }
}

fn compute(input: ComputeInput) {
    if !input.in_bounds { return; }
    let camera = ss_haze_camera();
    let query_key = camera.origin + vec3<i32>(input.cell);
    let output_index = ss_haze_r_index(query_key);
    var receiver_rgb = vec3<f32>(0.0);
    var receiver_flags = SS_HAZE_FIELD_INCOMPLETE;
    let enabled = ss_haze_air_header(camera) && local_haze && quality != 0u && ss_local_air_density() >= 0.00001;
    if enabled {
        let point = ss_haze_r_relative(query_key, camera);
        let density = ss_local_air_density();
        var strongest = 0.0;
        var tint_weight = 0.0;
        var tint_sum = vec3<f32>(0.0);
        // A centroid lies at most sqrt(12) from its two-block node. The
        // conservative radius7 stencil has integer squared offsets <=27:
        // all 619 nodes, not a nearest-N list or a 179-node centred stencil.
        for (var z = -5i; z <= 5i; z += 1i) {
            for (var y = -5i; y <= 5i; y += 1i) {
                for (var x = -5i; x <= 5i; x += 1i) {
                    if x*x + y*y + z*z > 27i { continue; }
                    let key = query_key + vec3<i32>(x, y, z);
                    if !ss_haze_active_r(key, camera) { continue; }
                    let base = ss_haze_r_record(key);
                    let identity = ss_world_light[base];
                    let evidence = ss_world_light[base + 3u];
                    // The child mask has an independent lifetime from receiver
                    // LIVE, but always requires the macrocell's full identity.
                    if !ss_haze_key_equal(identity.xyz, key) || evidence.y != frame.world_epoch { continue; }
                    if (identity.w & SS_HAZE_STATE_MASK) == SS_HAZE_LIVE {
                        let light = bitcast<vec4<f32>>(ss_world_light[base + 1u]);
                        let centroid = bitcast<vec4<f32>>(ss_world_light[base + 2u]);
                        let source = ss_haze_r_relative(key, camera) + centroid.xyz;
                        let separation = distance(source, point);
                        let freshness = ss_haze_fresh(centroid.w);
                        if separation < SS_HAZE_REACH && freshness > 0.0 {
                            receiver_flags |= SS_HAZE_FIELD_SUPPORTED;
                            if (identity.w & SS_HAZE_CURRENT) == 0u { receiver_flags |= SS_HAZE_FIELD_RETAINED; }
                            // Source-side classification prevents codec/mean
                            // rounding from making exclusively weak evidence strong.
                            if (evidence.x & SS_HAZE_HAS_STRONG) != 0u {
                                let power = ss_haze_transfer(max(15.0 * light.x - separation, 0.0));
                                let support = freshness * ss_haze_range(source);
                                if power * support > 0.0 {
                                    let weight = power * support * ss_haze_path_visibility(source, point)
                                        * exp(-density * separation);
                                    strongest = max(strongest, weight);
                                    tint_sum += light.yzw * weight;
                                    tint_weight += weight;
                                }
                            }
                        }
                    }
                }
            }
        }
        // Max of continuous weighted strengths is continuous at ties. Tint
        // blends every contributor; it never follows an argmax source identity.
        receiver_rgb = tint_sum * (strongest / max(tint_weight, 0.0000001));
    }
    // Receiver payload and arithmetic remain F-weighted linear colour.
    ss_world_light[SS_HAZE_B_AIR + output_index] = vec4<u32>(bitcast<vec3<u32>>(receiver_rgb), receiver_flags);
    let owner = input.cell.x + 32u * input.cell.y + 1024u * input.cell.z;
    ss_haze_write_sky_directory(owner, camera, enabled);
}
