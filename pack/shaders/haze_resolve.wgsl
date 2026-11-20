// SPDX-License-Identifier: Apache-2.0
// A is immutable. Each invocation owns one receiver and exactly eight emitters.
// Never gather another owner's old B record in this dispatch.
fn ss_haze_negative_witness(key: vec3<i32>, offset: vec3<f32>, packed_normal: u32,
    camera: SsHazeCamera, dimensions: vec2<u32>) -> bool {
    let witness = ss_haze_e_relative(key, offset, camera);
    if !ss_haze_local_position_valid(witness) { return false; }
    let clip = frame.projection * frame.view * vec4<f32>(witness, 1.0);
    if !(clip.w > 0.001) { return false; }
    let uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    if !all(uv > vec2<f32>(0.0)) || !all(uv < vec2<f32>(1.0)) { return false; }
    let pixel = vec2<i32>(uv * vec2<f32>(dimensions));
    let surface = surface_at(pixel);
    let decoded = ss_haze_decode_receiver(surface.smoothness, surface.present);
    if !decoded.valid || ss_metadata_emission(surface.data) > 0.0 { return false; }
    let depth = textureLoad(scene_depth, pixel, 0);
    if !(depth > 0.0000001) { return false; }
    let pixel_uv = (vec2<f32>(pixel) + vec2<f32>(0.5)) / vec2<f32>(dimensions);
    let point = view_position(pixel_uv, depth);
    if !ss_haze_local_position_valid(point) { return false; }
    if !ss_haze_e_witness_unambiguous(point, surface.normal, camera)
        || !all(ss_haze_e_key(point, surface.normal, decoded.inward, camera) == key) { return false; }
    // Both point and witness are camera-relative world coordinates.
    return distance(point, witness) <= 1.0 / 32.0
        && dot(surface.normal, ss_haze_unpack_normal(packed_normal)) >= 0.99;
}

fn ss_haze_resolve_emitter(key: vec3<i32>, camera: SsHazeCamera, elapsed: f32,
    dimensions: vec2<u32>, valid_frame: bool) -> bool {
    let base = ss_haze_e_record(key);
    let accum = ss_haze_e_accum(key);
    var identity = ss_world_light[base];
    var light = ss_world_light[base + 1u];
    var witness = ss_world_light[base + 2u];
    var evidence = ss_world_light[base + 3u];
    let old_matches = ss_haze_key_equal(identity.xyz, key) && evidence.z == frame.world_epoch;
    if !old_matches {
        identity = vec4<u32>(bitcast<vec3<u32>>(key), SS_HAZE_UNKNOWN);
        light = vec4<u32>(0u);
        witness = bitcast<vec4<u32>>(vec4<f32>(0.0, 0.0, 0.0, SS_HAZE_DEAD));
        evidence = vec4<u32>(0u, 0u, frame.world_epoch, 0u);
    }
    let old_state = identity.w & SS_HAZE_STATE_MASK;
    let age = ss_haze_advance_age(bitcast<f32>(witness.w), elapsed);
    identity.w = old_state;
    witness.w = bitcast<u32>(age);
    var positive = false;
    var conflict = false;
    var negative = false;
    var current_light = vec4<u32>(0u);
    var current_witness = vec4<u32>(0u);
    var current_evidence = vec4<u32>(0u, 0u, frame.world_epoch, 0u);
    if valid_frame {
        let expected = vec3<u32>(ss_light_accum[accum], ss_light_accum[accum + 1u], ss_light_accum[accum + 2u]);
        if ss_haze_key_equal(expected, key) {
            let count = ss_light_accum[accum + 3u];
            let minimum = ss_light_accum[accum + 7u];
            let maximum = ss_light_accum[accum + 8u];
            let token = ss_light_accum[accum + 9u];
            let flags = ss_light_accum[accum + 10u];
            if count > 0u {
                conflict = minimum != maximum || minimum == 0u || maximum > 15u
                    || (flags & SS_HAZE_E_BAD_GEOMETRY) != 0u;
                if token < ss_light_accum[10u] {
                    let pixel = vec2<i32>(i32(token % dimensions.x), i32(token / dimensions.x));
                    let surface = surface_at(pixel);
                    let decoded = ss_haze_decode_receiver(surface.smoothness, surface.present);
                    let depth = textureLoad(scene_depth, pixel, 0);
                    let uv = (vec2<f32>(pixel) + vec2<f32>(0.5)) / vec2<f32>(dimensions);
                    let point = view_position(uv, max(depth, 0.0000001));
                    let sample_level = u32(round(ss_metadata_emission(surface.data) * 15.0));
                    if decoded.valid && depth > 0.0000001 && ss_haze_local_position_valid(point)
                        && all(ss_haze_e_key(point, surface.normal, decoded.inward, camera) == key)
                        && sample_level == minimum {
                        let denominator = max(f32(count) * f32(ss_light_accum[11u]), 1.0);
                        let tint = clamp(vec3<f32>(f32(ss_light_accum[accum + 4u]),
                            f32(ss_light_accum[accum + 5u]), f32(ss_light_accum[accum + 6u])) / denominator,
                            vec3<f32>(0.0), vec3<f32>(1.0));
                        let offset = point - ss_haze_e_relative(key, vec3<f32>(0.0), camera);
                        current_light = bitcast<vec4<u32>>(vec4<f32>(f32(minimum), tint));
                        current_witness = bitcast<vec4<u32>>(vec4<f32>(offset, 0.0));
                        current_evidence = vec4<u32>(textureLoad(scene_surface, pixel, 0).x,
                            flags | SS_HAZE_E_WITNESS, frame.world_epoch, frame.frame_index);
                        positive = !conflict;
                    } else { conflict = true; }
                } else { conflict = true; }
            }
        }
        if old_matches && (evidence.y & SS_HAZE_E_WITNESS) != 0u
            && (old_state == SS_HAZE_LIVE || old_state == SS_HAZE_ZERO || old_state == SS_HAZE_AMBIGUOUS) {
            negative = ss_haze_negative_witness(key, bitcast<vec3<f32>>(witness.xyz),
                evidence.x, camera, dimensions);
        }
    }
    if !valid_frame {
        identity.w = SS_HAZE_UNKNOWN;
        light = vec4<u32>(0u);
        witness = bitcast<vec4<u32>>(vec4<f32>(0.0, 0.0, 0.0, SS_HAZE_DEAD));
        evidence = vec4<u32>(0u, 0u, frame.world_epoch, 0u);
    } else if conflict || (positive && negative) {
        identity.w = SS_HAZE_AMBIGUOUS | SS_HAZE_CURRENT;
        light = vec4<u32>(0u);
        if (current_evidence.y & SS_HAZE_E_WITNESS) != 0u {
            witness = current_witness;
            evidence = current_evidence;
        }
        witness.w = bitcast<u32>(0.0);
    } else if positive {
        identity.w = SS_HAZE_LIVE | SS_HAZE_CURRENT;
        light = current_light;
        witness = current_witness;
        evidence = current_evidence;
    } else if negative {
        identity.w = SS_HAZE_ZERO | SS_HAZE_CURRENT;
        light = vec4<u32>(0u);
        witness.w = bitcast<u32>(0.0);
    } else if age >= SS_HAZE_DEAD {
        identity.w = select(SS_HAZE_EXPIRED, SS_HAZE_UNKNOWN, old_state == SS_HAZE_UNKNOWN);
        light = vec4<u32>(0u);
    }
    identity = vec4<u32>(bitcast<vec3<u32>>(key), identity.w);
    evidence.z = frame.world_epoch;
    ss_world_light[base] = identity;
    ss_world_light[base + 1u] = light;
    ss_world_light[base + 2u] = witness;
    ss_world_light[base + 3u] = evidence;
    return (identity.w & SS_HAZE_STATE_MASK) == SS_HAZE_LIVE
        && bitcast<f32>(light.x) > 0.0 && bitcast<f32>(witness.w) < SS_HAZE_DEAD;
}

fn compute(input: ComputeInput) {
    if !input.in_bounds { return; }
    let camera = ss_haze_camera();
    let key = camera.origin + vec3<i32>(input.cell);
    let dimensions = vec2<u32>(ss_light_accum[8u], ss_light_accum[9u]);
    let valid_frame = camera.valid && all(textureDimensions(scene_depth) == dimensions)
        && ss_light_accum[0u] == SS_HAZE_MAGIC
        && ss_light_accum[1u] == SS_HAZE_SCHEMA && ss_light_accum[2u] == frame.world_epoch
        && ss_light_accum[3u] == frame.frame_index && ss_light_accum[14u] == SS_HAZE_HEADER_OK;
    let elapsed = clamp(bitcast<f32>(ss_light_accum[15u]), 0.0, SS_HAZE_DEAD);
    let base = ss_haze_r_record(key);
    let accum = ss_haze_r_accum(key);
    var identity = ss_world_light[base];
    var light = ss_world_light[base + 1u];
    var centroid = ss_world_light[base + 2u];
    var evidence = ss_world_light[base + 3u];
    if !ss_haze_key_equal(identity.xyz, key) || evidence.y != frame.world_epoch {
        identity = vec4<u32>(bitcast<vec3<u32>>(key), SS_HAZE_UNKNOWN);
        light = vec4<u32>(0u);
        centroid = bitcast<vec4<u32>>(vec4<f32>(0.0, 0.0, 0.0, SS_HAZE_DEAD));
        evidence = vec4<u32>(0u, frame.world_epoch, 0u, 0u);
    }
    let old_state = identity.w & SS_HAZE_STATE_MASK;
    let age = ss_haze_advance_age(bitcast<f32>(centroid.w), elapsed);
    identity.w = old_state | (identity.w & SS_HAZE_MIXED_FACE);
    centroid.w = bitcast<u32>(age);
    let expected = vec3<u32>(ss_light_accum[accum], ss_light_accum[accum + 1u], ss_light_accum[accum + 2u]);
    let weight = ss_light_accum[accum + 3u];
    if valid_frame && ss_haze_key_equal(expected, key) && weight > 0u {
        let denominator = f32(weight);
        var block = clamp(f32(ss_light_accum[accum + 4u]) / denominator, 0.0, 1.0);
        let flags = ss_light_accum[accum + 11u];
        if (flags & SS_HAZE_HAS_POSITIVE) == 0u { block = 0.0; }
        if (flags & SS_HAZE_HAS_STRONG) == 0u { block = min(block, 8.0 / 15.0); }
        let tint = clamp(vec3<f32>(f32(ss_light_accum[accum + 5u]),
            f32(ss_light_accum[accum + 6u]), f32(ss_light_accum[accum + 7u])) / denominator,
            vec3<f32>(0.0), vec3<f32>(1.0));
        let offset = clamp(vec3<f32>(f32(ss_light_accum[accum + 8u]),
            f32(ss_light_accum[accum + 9u]), f32(ss_light_accum[accum + 10u])) * (4.0 / denominator)
            - vec3<f32>(2.0), vec3<f32>(-2.0), vec3<f32>(2.0));
        identity.w = SS_HAZE_LIVE | SS_HAZE_CURRENT
            | select(0u, SS_HAZE_MIXED_FACE, ss_haze_mixed_faces(flags));
        light = bitcast<vec4<u32>>(vec4<f32>(block, tint));
        centroid = bitcast<vec4<u32>>(vec4<f32>(offset, 0.0));
        evidence = vec4<u32>(flags, frame.world_epoch, frame.frame_index, weight);
    } else if !valid_frame {
        identity.w = SS_HAZE_UNKNOWN;
        light = vec4<u32>(0u);
        centroid = bitcast<vec4<u32>>(vec4<f32>(0.0, 0.0, 0.0, SS_HAZE_DEAD));
        evidence = vec4<u32>(0u, frame.world_epoch, 0u, 0u);
    } else if age >= SS_HAZE_DEAD {
        identity.w = select(SS_HAZE_EXPIRED, SS_HAZE_UNKNOWN, old_state == SS_HAZE_UNKNOWN);
        light = vec4<u32>(0u);
    }
    var children = 0u;
    for (var child = 0u; child < 8u; child += 1u) {
        let emitter_key = key * vec3<i32>(2) + ss_haze_child(child);
        if ss_haze_resolve_emitter(emitter_key, camera, elapsed, dimensions, valid_frame) {
            children |= 1u << child;
        }
    }
    identity = vec4<u32>(bitcast<vec3<u32>>(key), identity.w);
    identity.w |= children << 8u;
    evidence.y = frame.world_epoch;
    ss_world_light[base] = identity;
    ss_world_light[base + 1u] = light;
    ss_world_light[base + 2u] = centroid;
    ss_world_light[base + 3u] = evidence;
    if all(input.cell == vec3<u32>(0u)) {
        for (var row = 0u; row < 4u; row += 1u) {
            let word = row * 4u;
            ss_world_light[row] = vec4<u32>(ss_light_accum[word], ss_light_accum[word + 1u],
                ss_light_accum[word + 2u], ss_light_accum[word + 3u]);
        }
        // A[15] is elapsed clock time; B[15] is this frame's clock. Other
        // resolve invocations read A only, so this cannot race a header read.
        ss_world_light[3u].w = bitcast<u32>(frame.time);
    }
}
