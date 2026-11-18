// SPDX-License-Identifier: Apache-2.0
// Visible-source field helpers, included only by post stages. Propagation
// stores source coordinates, so a moving source never snaps to a coarse cell.
fn ss_emitter_ray(uv: vec2<f32>) -> vec3<f32> {
    return normalize(view_position(uv, 0.5));
}

fn ss_emitter_code(source: vec4<f32>) -> u32 {
    return u32(max(round(source.w) - 1.0, 0.0));
}

fn ss_emitter_pixel(source: vec4<f32>) -> vec2<i32> {
    let index = ss_emitter_code(source) & 15u;
    return vec2<i32>(round(source.xy)) * 4 + vec2<i32>(i32(index & 3u), i32(index >> 2u));
}

fn ss_emitter_uv(source: vec4<f32>) -> vec2<f32> {
    return (vec2<f32>(ss_emitter_pixel(source)) + vec2<f32>(0.5)) / frame.resolution;
}

fn ss_emitter_strength(source: vec4<f32>) -> f32 {
    return f32(ss_emitter_code(source) >> 4u) / 15.0;
}

fn ss_emitter_position(source: vec4<f32>) -> vec3<f32> {
    return ss_emitter_ray(ss_emitter_uv(source)) * source.z;
}

// Rank by distance from the source to the camera ray in world blocks.
// The eventual scattering pass stops that ray at actual scene depth and
// performs visibility checks. Propagation itself must cross silhouette cells.
fn ss_emitter_rank(source: vec4<f32>, ray: vec3<f32>) -> f32 {
    if source.w <= 0.0 || source.z <= 0.0 { return 0.0; }
    let position = ss_emitter_position(source);
    let along = max(dot(position, ray), 0.0);
    let separation = position - ray * along;
    let distance_squared = dot(separation, separation);
    return ss_emitter_strength(source) / (0.25 + distance_squared);
}

// Search cost is bounded on very large targets. Its circular fade is bounded
// by the same discoverable radius, so no supported resolution exposes a hard
// boundary where the propagated source field runs out.
fn ss_emitter_search_radius() -> i32 {
    let scale = max(frame.resolution.y / 540.0, 1.0);
    return clamp(i32(ceil((21.0 * scale - 4.0) / 9.0)), 2i, 7i);
}

fn ss_emitter_support_radius() -> f32 {
    let available = f32((ss_emitter_search_radius() * 9i + 4i) * 4i - 6i);
    return min(82.0 * max(frame.resolution.y / 540.0, 1.0), available);
}

fn ss_emitter_tie_before(candidate: vec4<f32>, current: vec4<f32>) -> bool {
    let candidate_pixel = ss_emitter_pixel(candidate);
    let current_pixel = ss_emitter_pixel(current);
    if candidate_pixel.x != current_pixel.x { return candidate_pixel.x < current_pixel.x; }
    return candidate_pixel.y < current_pixel.y;
}
