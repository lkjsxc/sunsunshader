// SPDX-License-Identifier: Apache-2.0
// Preserve a visible emitter's actual native pixel and distance. A max over
// the complete 4x4 footprint retains thin torches that an average can erase.
// Only material emission qualifies; a bright wall, cloud or sky never seeds.
fn post(input: PostInput) -> vec4<f32> {
    if !local_haze || quality == 0u || ss_local_air_density() < 0.00001 { return vec4<f32>(0.0); }
    let dimensions = vec2<i32>(textureDimensions(scene_color));
    let cell = vec2<i32>(input.pixel);
    let first = cell * 4;
    var best = vec4<f32>(0.0);
    var best_rank = 0.0;
    var best_center = 100.0;
    for (var y = 0i; y < 4i; y += 1i) {
        for (var x = 0i; x < 4i; x += 1i) {
            let pixel = first + vec2<i32>(x, y);
            if any(pixel >= dimensions) { continue; }
            let surface = surface_at(pixel);
            if !surface.present { continue; }
            let emission = clamp(ss_metadata_emission(surface.data), 0.0, 1.0);
            let level = u32(round(emission * 15.0));
            if level == 0u { continue; }
            let source_color = ss_decode(textureLoad(scene_color, pixel, 0).rgb);
            let rank = emission * max(source_color.r, max(source_color.g, source_color.b));
            let delta = vec2<f32>(f32(x) - 1.5, f32(y) - 1.5);
            let center = dot(delta, delta);
            if rank > best_rank || (rank == best_rank && center < best_center) {
                let uv = (vec2<f32>(pixel) + vec2<f32>(0.5)) / vec2<f32>(dimensions);
                let depth = textureLoad(scene_depth, pixel, 0);
                if depth <= 0.0000001 { continue; }
                let packed = 1u + level * 16u + u32(x + y * 4);
                best = vec4<f32>(vec2<f32>(cell), length(view_position(uv, depth)), f32(packed));
                best_rank = rank;
                best_center = center;
            }
        }
    }
    // xy: original quarter-resolution cell; z: source distance in blocks.
    // w: 1 + 16 * emission level + native subpixel index (x + 4*y).
    // The integer cell plus a 0..255 code preserves an exact native source
    // pixel even when a half-float cannot hold every full-resolution pixel.
    // Zero w is the absence marker. These are data, never filtered colours.
    return best;
}
