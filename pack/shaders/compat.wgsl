// SPDX-License-Identifier: Apache-2.0
// The released Nightly stores the world in display-referred gamma (API 0.1).
// Keep our lighting and intermediate post passes linear; cross that boundary
// only at native inputs/outputs and the first/last post passes. The exponent
// matches the public Horizon colour-space contract, not a borrowed shader.
fn ss_decode(color: vec3<f32>) -> vec3<f32> {
    return pow(max(color, vec3<f32>(0.0)), vec3<f32>(2.2));
}

fn ss_encode(color: vec3<f32>) -> vec3<f32> {
    // Keep the original hue when the Nightly's bounded world target cannot
    // carry a highlight's full energy. Independent clipping loses that hue.
    let positive = max(color, vec3<f32>(0.0));
    let peak = max(positive.r, max(positive.g, positive.b));
    return pow(positive / max(peak, 1.0), vec3<f32>(1.0 / 2.2));
}

fn ss_decode_light(color: vec4<f32>) -> vec4<f32> {
    return vec4<f32>(ss_decode(color.rgb), color.a);
}

// The released Nightly writes a fallback up-vector when shadow maps are off.
// Derive the same active celestial light without requiring a shadow camera.
fn ss_light_direction() -> vec3<f32> {
    if frame.has_shadow != 0u { return frame.light_direction; }
    return select(frame.moon_direction, frame.sun_direction, frame.sun_direction.y >= 0.0);
}
