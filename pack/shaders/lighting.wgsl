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
    let sky_level = clamp(light.y, 0.0, 1.0);
    let open = pow(sky_level, 2.4);
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
    if frame.dimension == 0 {
        // Skylight is a visibility signal. Indirect sky light survives beneath
        // leaves without letting the direct sun reach enclosed surfaces.
        // Ease only the high-sun response: the established twilight stays intact.
        let high_sun = smoothstep(0.10, 0.42, frame.sun_direction.y)
            * (1.0 - frame.rain * 0.50);
        let indirect_open = mix(open, pow(sky_level, 1.20), high_sun);
        let deep_night = night * (1.0 - smoothstep(-0.35, -0.20, frame.sun_direction.y));
        let clear_fill = blue_fill + vec3<f32>(0.040, 0.065, 0.100) * high_sun;
        // Redistribute daylight toward open shade using the shadow result
        // already available. This leaves the sunlit response and caves intact.
        let shaded = 1.0 - clamp(dot(visibility, vec3<f32>(1.0 / 3.0)), 0.0, 1.0);
        let shade_fill = 1.0 + 2.10 * high_sun * shaded;
        let indirect = clear_fill * (0.12 + 0.70 * day) * shade_fill
            + vec3<f32>(0.012, 0.025, 0.050) * deep_night;
        let clear_sun = sun * (1.0 + high_sun * 0.08);
        let clear_moon = moon + vec3<f32>(0.065, 0.11, 0.17) * moon_diffuse * deep_night;
        illumination = indirect_open * indirect * sky_direction
            + open * (clear_sun + clear_moon + ss_sun_color() * transmitted) * visibility;
    }
    if frame.dimension == 1 {
        let island_facing = max(dot(normal, ss_light_direction()), 0.0);
        illumination = vec3<f32>(0.11, 0.12, 0.20) * (0.55 + 0.45 * max(normal.y, 0.0))
            + vec3<f32>(0.42, 0.48, 0.78) * (0.25 + 0.75 * island_facing) * visibility;
    }
    // Light levels carry occlusion. Source colours only tint that surviving light.
    let block_level = clamp(light.x, 0.0, 1.0);
    let warm = vec3<f32>(1.0, 0.43, 0.15);
    let lamp = mix(warm, source_color.rgb, clamp(source_color.a, 0.0, 1.0));
    illumination += lamp * (pow(block_level, 2.15) * 1.8);
    illumination += dynamic_light * 1.25;
    illumination += vec3<f32>(0.006, 0.009, 0.016) * (0.7 + 0.3 * frame.brightness);
    if frame.dimension == -1 {
        illumination += ss_decode(frame.fog_color) * 0.28 + vec3<f32>(0.06, 0.018, 0.008);
    }
    return mix(illumination, max(illumination, vec3<f32>(0.9)), frame.night_vision);
}

fn ss_surface_emission(albedo: vec3<f32>, amount: f32) -> vec3<f32> {
    return albedo * amount * (1.4 + 2.0 * amount);
}
