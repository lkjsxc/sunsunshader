// SPDX-License-Identifier: Apache-2.0
// First base-three propagation step. Read the seed before bloom reuses it.
fn post(input: PostInput) -> vec4<f32> {
    if !local_haze || quality == 0u || ss_local_air_density() < 0.00001 { return vec4<f32>(0.0); }
    let size = vec2<i32>(textureDimensions(ss_bright));
    let center = clamp(vec2<i32>(input.uv * vec2<f32>(size)), vec2<i32>(0), size - 1);
    let ray = ss_emitter_ray(input.uv);
    let resolution_scale = max(frame.resolution.y / 540.0, 1.0);
    let radius = clamp(i32(ceil((21.0 * resolution_scale - 4.0) / 9.0)), 2i, 7i);
    var best = vec4<f32>(0.0);
    for (var y = -radius; y <= radius; y += 1i) {
        for (var x = -radius; x <= radius; x += 1i) {
            let texel = center + vec2<i32>(x, y) * 9;
            if any(texel < vec2<i32>(0)) || any(texel >= size) { continue; }
            let source = textureLoad(ss_bright, texel, 0);
            if ss_emitter_prefer(source, best, ray) { best = source; }
        }
    }
    return best;
}
