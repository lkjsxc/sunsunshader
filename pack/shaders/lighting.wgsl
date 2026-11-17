// SPDX-License-Identifier: Apache-2.0
// Original radiometric balance: directional visibility controls direct light;
// the voxel skylight controls diffuse sky and ground bounce, independently.

fn ss_face_shade(normal: vec3<f32>) -> f32 {
    let vertical = select(0.5, 1.0, normal.y > 0.0);
    let face = dot(abs(normal), vec3<f32>(0.6, vertical, 0.8));
    return pow(clamp(face, 0.5, 1.0), 2.2);
}

fn ss_surface_light(
    normal: vec3<f32>, view: vec3<f32>, light: vec2<f32>,
    visibility: vec3<f32>, source_color: vec4<f32>,
    dynamic_light: vec3<f32>, foliage: f32,
) -> vec3<f32> {
    let day = ss_daylight();
    let night = ss_moonlight();
    let sky_level = clamp(light.y, 0.0, 1.0);
    let open = pow(sky_level, 0.95);
    let up = max(normal.y, 0.0);
    let sky_direction = 0.66 + 0.34 * up;
    let rain = frame.rain;
    let direct_weather = 1.0 - rain * 0.88;
    let ndl = max(dot(normal, frame.sun_direction), 0.0);
    let ndm = max(dot(normal, frame.moon_direction), 0.0);
    // Do not extinguish a real sun patch twice: a leaf roof reduces the voxel
    // skylight even at an opening whose directional shadow sample is clear.
    let direct_open = select(pow(sky_level, 2.2), smoothstep(0.015, 0.38, sky_level),
        shadows && frame.has_shadow != 0u);
    let sky_fill = mix(vec3<f32>(0.235, 0.31, 0.45), vec3<f32>(0.31, 0.34, 0.39), rain);
    let sky = sky_fill * (0.78 * day) + vec3<f32>(0.034, 0.050, 0.080) * night;
    let bounce = vec3<f32>(0.070, 0.058, 0.040) * day * (1.0 - rain * 0.45)
        * (0.75 - 0.40 * up);
    let sunlight = ss_sun_color() * (1.72 * ndl * day * direct_weather);
    let moonlight = vec3<f32>(0.17, 0.25, 0.40) * ndm * night;
    let backlit = pow(max(dot(view, -frame.sun_direction), 0.0), 3.0);
    let transmission = foliage * (0.16 + 0.52 * backlit)
        * day * direct_weather * (0.35 + 0.65 * abs(dot(normal, frame.sun_direction)));
    var illumination = open * (sky * sky_direction + bounce)
        + direct_open * visibility * (sunlight + moonlight + ss_sun_color() * transmission);
    if frame.dimension == 1 {
        let island_facing = max(dot(normal, ss_light_direction()), 0.0);
        illumination = vec3<f32>(0.11, 0.12, 0.20) * (0.55 + 0.45 * up)
            + vec3<f32>(0.42, 0.48, 0.78) * (0.25 + 0.75 * island_facing) * visibility;
    }
    let block_level = clamp(light.x, 0.0, 1.0);
    let lamp = mix(vec3<f32>(1.0, 0.48, 0.21), source_color.rgb, clamp(source_color.a, 0.0, 1.0));
    illumination += lamp * (pow(block_level, 2.35) * 2.05);
    illumination += dynamic_light * 1.35;
    illumination += vec3<f32>(0.004, 0.005, 0.008) * (0.7 + 0.3 * frame.brightness);
    if frame.dimension == -1 {
        illumination += ss_decode(frame.fog_color) * 0.28 + vec3<f32>(0.06, 0.018, 0.008);
    }
    return mix(illumination, max(illumination, vec3<f32>(0.9)), frame.night_vision);
}

fn ss_surface_emission(albedo: vec3<f32>, amount: f32) -> vec3<f32> {
    return albedo * amount * (1.0 + 1.1 * amount);
}
