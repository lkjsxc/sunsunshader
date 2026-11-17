// SPDX-License-Identifier: Apache-2.0
// This lighting model is authored for Sunsun Shader in linear light.

fn ss_face_shade(normal: vec3<f32>) -> f32 {
    let vertical = select(0.5, 1.0, normal.y > 0.0);
    let face = dot(abs(normal), vec3<f32>(0.6, vertical, 0.8));
    return pow(clamp(face, 0.5, 1.0), 2.2);
}

fn ss_surface_light(
    normal: vec3<f32>,
    view: vec3<f32>,
    light: vec2<f32>,
    visibility: vec3<f32>,
    source_color: vec4<f32>,
    dynamic_light: vec3<f32>,
    foliage: f32,
) -> vec3<f32> {
    let day = ss_daylight();
    let night = ss_moonlight();
    let open = pow(clamp(light.y, 0.0, 1.0), 2.4);
    let sky_direction = 0.65 + 0.35 * max(normal.y, 0.0);
    let cloud_dimming = 1.0 - frame.rain * 0.72;
    let diffuse = max(dot(normal, frame.sun_direction), 0.0);
    let moon_diffuse = max(dot(normal, frame.moon_direction), 0.0);
    let blue_fill = mix(vec3<f32>(0.19, 0.27, 0.40), vec3<f32>(0.34, 0.43, 0.55), frame.rain);
    let sun = ss_sun_color() * (1.5 * diffuse * day * cloud_dimming);
    let moon = vec3<f32>(0.065, 0.10, 0.19) * moon_diffuse * night;
    let transmitted = pow(max(dot(view, -frame.sun_direction), 0.0), 5.0)
        * foliage * day * cloud_dimming * 0.42;
    var illumination = open * (
        blue_fill * sky_direction * (0.12 + 0.70 * day)
        + (sun + moon + ss_sun_color() * transmitted) * visibility
    );
    // Light levels carry occlusion. Source colours only tint that surviving light.
    let block_level = clamp(light.x, 0.0, 1.0);
    let warm = vec3<f32>(1.0, 0.43, 0.15);
    let lamp = mix(warm, source_color.rgb, clamp(source_color.a, 0.0, 1.0));
    illumination += lamp * (pow(block_level, 2.15) * 1.8);
    illumination += dynamic_light * 1.25;
    illumination += vec3<f32>(0.006, 0.009, 0.016) * (0.7 + 0.3 * frame.brightness);
    if frame.dimension == -1 {
        illumination += frame.fog_color * 0.28 + vec3<f32>(0.06, 0.018, 0.008);
    }
    if frame.dimension == 1 {
        illumination += vec3<f32>(0.12, 0.14, 0.23) * (0.6 + 0.4 * max(normal.y, 0.0));
    }
    return mix(illumination, max(illumination, vec3<f32>(0.9)), frame.night_vision);
}

fn ss_surface_emission(albedo: vec3<f32>, amount: f32) -> vec3<f32> {
    return albedo * amount * (1.4 + 2.0 * amount);
}
