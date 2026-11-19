// SPDX-License-Identifier: Apache-2.0
// API 0.2 supplies and accepts linear light. Horizon owns every colour transfer.
// Retain rc3's hue-preserving world range independently of gamma encoding:
// removing this bound would turn the compatibility port into a new HDR look.
fn ss_world_bound(color: vec3<f32>) -> vec3<f32> {
    let positive = max(color, vec3<f32>(0.0));
    let peak = max(positive.r, max(positive.g, positive.b));
    return positive / max(peak, 1.0);
}

// Retain rc3's celestial fallback when shadows are disabled. The new API also
// supplies a valid light_direction in that case; no new shadow behavior is needed.
fn ss_light_direction() -> vec3<f32> {
    if frame.has_shadow != 0u { return frame.light_direction; }
    return select(frame.moon_direction, frame.sun_direction, frame.sun_direction.y >= 0.0);
}
