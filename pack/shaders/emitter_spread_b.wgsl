// SPDX-License-Identifier: Apache-2.0
// Second base-three step. The final scattering pass gathers stride one.
fn post(input: PostInput) -> vec4<f32> {
    if !local_haze || quality == 0u || ss_local_air_density() < 0.00001 { return vec4<f32>(0.0); }
    let size = vec2<i32>(textureDimensions(ss_blur));
    let center = clamp(vec2<i32>(input.uv * vec2<f32>(size)), vec2<i32>(0), size - 1);
    let ray = ss_emitter_ray(input.uv);
    var best = vec4<f32>(0.0);
    var best_rank = 0.0;
    for (var y = -1i; y <= 1i; y += 1i) {
        for (var x = -1i; x <= 1i; x += 1i) {
            let texel = center + vec2<i32>(x, y) * 3;
            if any(texel < vec2<i32>(0)) || any(texel >= size) { continue; }
            let source = textureLoad(ss_blur, texel, 0);
            let rank = ss_emitter_rank(source, ray);
            if rank > best_rank || (rank == best_rank && ss_emitter_tie_before(source, best)) {
                best = source;
                best_rank = rank;
            }
        }
    }
    return best;
}
