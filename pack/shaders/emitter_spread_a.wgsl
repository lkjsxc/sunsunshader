// SPDX-License-Identifier: Apache-2.0
// First base-three propagation step. Read the seed before bloom reuses it.
fn post(input: PostInput) -> vec4<f32> {
    if !local_haze || quality == 0u || ss_local_air_density() < 0.00001 { return vec4<f32>(0.0); }
    let size = vec2<i32>(textureDimensions(ss_bright));
    let center = clamp(vec2<i32>(input.uv * vec2<f32>(size)), vec2<i32>(0), size - 1);
    let ray = ss_emitter_ray(input.uv);
    let radius = ss_emitter_search_radius();
    var best = vec4<f32>(0.0);
    var best_rank = 0.0;
    for (var y = -radius; y <= radius; y += 1i) {
        for (var x = -radius; x <= radius; x += 1i) {
            let texel = center + vec2<i32>(x, y) * 9;
            if any(texel < vec2<i32>(0)) || any(texel >= size) { continue; }
            let source = textureLoad(ss_bright, texel, 0);
            let rank = ss_emitter_rank(source, ray);
            if rank > best_rank || (rank == best_rank && ss_emitter_tie_before(source, best)) {
                best = source;
                best_rank = rank;
            }
        }
    }
    return best;
}
