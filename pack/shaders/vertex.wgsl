// SPDX-License-Identifier: Apache-2.0
// Original world-anchored bending. The engine uses this same displacement
// in the terrain and caster passes, so moving plants keep their cast shadows.
fn vertex(input: VertexInput) -> vec3<f32> {
    if !wind || input.material < 10u || input.material > 13u {
        return input.position;
    }
    let world = input.position + frame.camera_position;
    let clock = frame.time * (SS_TAU / 3600.0);
    let long_wave = sin(dot(world.xz, vec2<f32>(0.31, 0.19)) + clock * 419.0);
    let flutter = sin(dot(world, vec3<f32>(1.1, 0.67, -0.83)) - clock * 953.0);
    let gust = 0.65 + 0.35 * sin(dot(world.xz, vec2<f32>(0.043, -0.057)) + clock * 157.0);
    let openness = smoothstep(0.05, 0.60, input.light.y);
    var anchor = clamp(1.0 - input.uv.y, 0.0, 1.0);
    var strength = 0.075;
    if input.material == 10u { anchor = 1.0; strength = 0.025; }
    if input.material == 12u { anchor *= 0.5; strength = 0.12; }
    if input.material == 13u { anchor = 0.5 + anchor * 0.5; strength = 0.12; }
    let sway = (long_wave + flutter * 0.23) * gust * strength * anchor * openness;
    return input.position + vec3<f32>(sway, -abs(sway) * anchor * 0.12, sway * 0.43);
}
