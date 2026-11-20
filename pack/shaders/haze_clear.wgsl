// SPDX-License-Identifier: Apache-2.0
// One owner per receiver macrocell and its eight child emitter cells.
// Prior B is immutable throughout this pass; A is the only write target.
fn compute(input: ComputeInput) {
    if !input.in_bounds { return; }
    let camera = ss_haze_camera();
    let key = camera.origin + vec3<i32>(input.cell);
    let receiver = ss_haze_r_accum(key);
    for (var word = 0u; word < 12u; word += 1u) {
        atomicStore(&ss_light_accum[receiver + word], 0u);
    }
    atomicStore(&ss_light_accum[receiver], bitcast<u32>(key.x));
    atomicStore(&ss_light_accum[receiver + 1u], bitcast<u32>(key.y));
    atomicStore(&ss_light_accum[receiver + 2u], bitcast<u32>(key.z));
    for (var child = 0u; child < 8u; child += 1u) {
        let emitter_key = key * vec3<i32>(2) + ss_haze_child(child);
        let emitter = ss_haze_e_accum(emitter_key);
        for (var word = 0u; word < 11u; word += 1u) {
            atomicStore(&ss_light_accum[emitter + word], 0u);
        }
        atomicStore(&ss_light_accum[emitter], bitcast<u32>(emitter_key.x));
        atomicStore(&ss_light_accum[emitter + 1u], bitcast<u32>(emitter_key.y));
        atomicStore(&ss_light_accum[emitter + 2u], bitcast<u32>(emitter_key.z));
        atomicStore(&ss_light_accum[emitter + 7u], 0xffffffffu);
        atomicStore(&ss_light_accum[emitter + 9u], 0xffffffffu);
    }
    if any(input.cell != vec3<u32>(0u)) { return; }
    var dimensions = vec2<u32>(0u);
    var pixels = 0u;
    var emitter_q = 0u;
    var valid = camera.valid;
    if all(frame.resolution >= vec2<f32>(1.0)) && all(frame.resolution < vec2<f32>(2147483648.0)) {
        dimensions = vec2<u32>(frame.resolution);
        if dimensions.y > 0u && dimensions.x <= 0xffffffffu / dimensions.y {
            pixels = dimensions.x * dimensions.y;
            emitter_q = min(2048u, 0xffffffffu / pixels);
        } else { valid = false; }
    } else { valid = false; }
    let previous = ss_world_light[0u];
    var elapsed = 0.0;
    if previous.x == SS_HAZE_MAGIC && previous.y == SS_HAZE_SCHEMA
        && previous.z == frame.world_epoch && ss_world_light[3u].z == SS_HAZE_HEADER_OK {
        elapsed = ss_haze_clock_delta(bitcast<f32>(ss_world_light[3u].w));
    }
    let mode = select(1u, 4u, quality >= 2u);
    let q = select(32768u, 8192u, quality >= 2u);
    let header = array<u32, 16>(
        SS_HAZE_MAGIC, SS_HAZE_SCHEMA, frame.world_epoch, frame.frame_index,
        bitcast<u32>(camera.origin.x), bitcast<u32>(camera.origin.y), bitcast<u32>(camera.origin.z), 32u,
        dimensions.x, dimensions.y, pixels, emitter_q,
        mode, q, select(0u, SS_HAZE_HEADER_OK, valid), bitcast<u32>(elapsed)
    );
    for (var word = 0u; word < 16u; word += 1u) { atomicStore(&ss_light_accum[word], header[word]); }
}
