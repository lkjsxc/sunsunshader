// SPDX-License-Identifier: Apache-2.0

fn ss_screen_direction(uv: vec2<f32>) -> vec3<f32> {
    let point = frame.projection_inverse * vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.00001, 1.0);
    return normalize((frame.view_inverse * vec4<f32>(point.xyz, 0.0)).xyz);
}

fn ss_contact_occlusion(input: PostInput, position: vec3<f32>) -> f32 {
    if quality == 0u { return 1.0; }
    let surface = surface_at(vec2<i32>(input.uv * frame.resolution));
    if !surface.present { return 1.0; }
    let radius = clamp(frame.projection[1].y * frame.resolution.y * 0.65
        / max(length(position), 1.0), 2.0, 12.0);
    let count = select(4u, 8u, quality >= 2u);
    var occlusion = 0.0;
    for (var i = 0u; i < count; i += 1u) {
        let angle = (f32(i) + 0.37) * 6.283185307 / f32(count);
        let uv = clamp(input.uv + vec2<f32>(cos(angle), sin(angle)) * radius / frame.resolution,
            vec2<f32>(0.001), vec2<f32>(0.999));
        let depth = depth_at(uv);
        if depth > 0.000001 {
            let delta = view_position(uv, depth) - position;
            let distance = length(delta);
            let facing = max(dot(surface.normal, delta / max(distance, 0.001)) - 0.16, 0.0);
            occlusion += facing * (1.0 - smoothstep(0.2, 1.6, distance)) * smoothstep(0.015, 0.08, distance);
        }
    }
    return 1.0 - occlusion * (0.24 / f32(count));
}

fn ss_air_shafts(position: vec3<f32>, pixel: vec2<f32>) -> vec3<f32> {
    if quality == 0u || frame.dimension != 0 || frame.in_water > 0.9 { return vec3<f32>(0.0); }
    let day = ss_daylight();
    let outside = smoothstep(0.04, 0.65, frame.eye_light_smooth.y);
    if day < 0.01 || outside < 0.01 { return vec3<f32>(0.0); }
    let distance = min(length(position), 96.0);
    let ray = normalize(position);
    var count = 6u;
    if quality >= 2u { count = 10u; }
    if quality >= 3u { count = 16u; }
    let jitter = ss_hash3(vec3<i32>(vec2<i32>(pixel), 27));
    var light = 0.0;
    for (var i = 0u; i < count; i += 1u) {
        let along = (f32(i) + 0.15 + jitter * 0.70) * distance / f32(count);
        light += ss_shadow_visibility(ray * along) * exp(-along * 0.004);
    }
    light /= f32(count);
    // Single scattering uses the Henyey-Greenstein phase named in atmosphere.wgsl.
    let phase = min(ss_phase_aerosol(dot(ray, frame.sun_direction), 0.62) * 12.56637, 5.0);
    let density = (0.0018 + 0.006 * frame.rain) * haze;
    let scattered = (1.0 - exp(-distance * density)) * phase * light;
    return ss_sun_color() * scattered * day * outside * 0.14 * (1.0 - 0.78 * frame.thunder);
}

fn post(input: PostInput) -> vec4<f32> {
    if input.depth <= 0.0000001 {
        let direction = ss_screen_direction(input.uv);
        var background = input.color.rgb;
        if frame.dimension == -1 || frame.dimension == 1 {
            background = ss_dimension_sky(direction);
        }
        background = ss_cloud_composite(background, direction, 12000.0);
        let sky_distance = max(frame.far, frame.render_distance);
        return vec4<f32>(ss_camera_fog(background, background, sky_distance), 1.0);
    }
    let position = view_position(input.uv, input.depth);
    let surface = input.color.rgb * ss_contact_occlusion(input, position);
    let air = ss_fog(surface, position) + ss_air_shafts(position, input.pixel);
    let result = ss_cloud_composite(air, normalize(position), length(position));
    return vec4<f32>(result, 1.0);
}
