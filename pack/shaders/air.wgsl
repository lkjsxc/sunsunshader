// SPDX-License-Identifier: Apache-2.0

fn ss_screen_direction(uv: vec2<f32>) -> vec3<f32> {
    let point = frame.projection_inverse * vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.00001, 1.0);
    return normalize((frame.view_inverse * vec4<f32>(point.xyz, 0.0)).xyz);
}

// Original screen-space contact integral: nearby geometry above a surface
// normal removes part of its diffuse fill. Fixed world geometry, no frame jitter.
fn ss_contact_occlusion(input: PostInput, position: vec3<f32>) -> f32 {
    if !contact_shading || quality == 0u { return 1.0; }
    let surface = surface_at(vec2<i32>(input.uv * frame.resolution));
    if !surface.present || ss_metadata_emission(surface.data) > 0.01 { return 1.0; }
    let view_depth = max(-(frame.view * vec4<f32>(position, 1.0)).z, 0.25);
    let pixels_per_block = frame.projection[1].y * frame.resolution.y * 0.5 / view_depth;
    let count = select(8u, 12u, quality >= 2u);
    var integral = 0.0;
    for (var i = 0u; i < count; i += 1u) {
        let angle = f32(i) * 2.39996323 + 0.41;
        let reach = select(0.38, 1.05, (i & 1u) != 0u);
        let radius = clamp(pixels_per_block * reach, 1.5, 28.0);
        let uv = clamp(input.uv + vec2<f32>(cos(angle), sin(angle)) * radius / frame.resolution,
            vec2<f32>(0.001), vec2<f32>(0.999));
        let depth = depth_at(uv);
        if depth > 0.000001 {
            let delta = view_position(uv, depth) - position;
            let distance = length(delta);
            let elevation = max(dot(surface.normal, delta / max(distance, 0.001)) - 0.07, 0.0);
            let range = (1.0 - smoothstep(0.35, 1.65, distance)) * smoothstep(0.025, 0.10, distance);
            integral += elevation * range;
        }
    }
    return clamp(1.0 - integral * (1.65 / f32(count)), 0.50, 1.0);
}

fn ss_air_shafts(position: vec3<f32>, pixel: vec2<f32>) -> vec3<f32> {
    if quality < 2u || !light_shafts || frame.dimension != 0 || frame.in_water > 0.9 { return vec3<f32>(0.0); }
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
    let cloud_visibility = ss_cloud_transmittance(ray * distance * 0.5);
    for (var i = 0u; i < count; i += 1u) {
        let along = (f32(i) + 0.15 + jitter * 0.70) * distance / f32(count);
        light += ss_terrain_visibility(ray * along) * exp(-along * 0.004);
    }
    light *= cloud_visibility / f32(count);
    // Single scattering uses the Henyey-Greenstein phase named in atmosphere.wgsl.
    let phase = min(ss_phase_aerosol(dot(ray, frame.sun_direction), 0.62) * 12.56637, 5.0);
    let density = (0.0018 + 0.006 * frame.rain) * haze;
    let scattered = (1.0 - exp(-distance * density)) * phase * light;
    return ss_sun_color() * scattered * day * outside * 0.14 * (1.0 - 0.78 * frame.thunder);
}

// Bilateral reconstruction keeps quarter-resolution air on its own depth
// layer. A near wall does not inherit the glow computed for a ray behind it.
fn ss_visible_light_air(uv: vec2<f32>, distance: f32) -> vec3<f32> {
    if !local_haze || quality == 0u || ss_local_air_density() < 0.00001 { return vec3<f32>(0.0); }
    let dimensions = vec2<i32>(textureDimensions(ss_haze));
    let coordinate = uv * vec2<f32>(dimensions) - vec2<f32>(0.5);
    let base = vec2<i32>(floor(coordinate));
    let fraction = fract(coordinate);
    var colour = vec3<f32>(0.0);
    var weight = 0.0;
    for (var y = 0i; y < 2i; y += 1i) {
        for (var x = 0i; x < 2i; x += 1i) {
            let texel = clamp(base + vec2<i32>(x, y), vec2<i32>(0), dimensions - 1);
            let sample = textureLoad(ss_haze, texel, 0);
            let bilinear = select(1.0 - fraction.x, fraction.x, x == 1i)
                * select(1.0 - fraction.y, fraction.y, y == 1i);
            let depth_weight = 1.0 - smoothstep(0.35 + distance * 0.015,
                1.0 + distance * 0.035, abs(sample.a - distance));
            let w = bilinear * depth_weight;
            colour += sample.rgb * w;
            weight += w;
        }
    }
    return colour / max(weight, 0.00001);
}

fn post(source: PostInput) -> vec4<f32> {
    var input = source;
    input.color = vec4<f32>(ss_decode(source.color.rgb), source.color.a);
    if input.depth <= 0.0000001 {
        let direction = ss_screen_direction(input.uv);
        var background = input.color.rgb;
        if frame.dimension == -1 || frame.dimension == 1 {
            background = ss_dimension_sky(direction);
        }
        background += ss_visible_moon_air(direction);
        background = ss_cloud_composite(background, direction, 12000.0);
        let sky_distance = max(frame.far, frame.render_distance);
        return vec4<f32>(ss_camera_fog(background, background, sky_distance)
            + ss_visible_light_air(input.uv, max(frame.render_distance, 64.0)), 1.0);
    }
    let position = view_position(input.uv, input.depth);
    let metadata = surface_at(vec2<i32>(input.uv * frame.resolution));
    // Native API 0.1 clips radiance before post. The known terrain emitter
    // strength survives in our metadata, allowing a restrained source-only
    // bloom boost; ordinary surfaces and native entities are not guessed.
    let emitter = select(0.0, ss_metadata_emission(metadata.data), metadata.present);
    let surface = input.color.rgb * ss_contact_occlusion(input, position) * (1.0 + emitter * 1.35);
    let sky_light = select(frame.eye_light_smooth.y, ss_metadata_sky(metadata.data), metadata.present);
    let air = ss_fog(surface, position, sky_light) + ss_air_shafts(position, input.pixel);
    let result = ss_cloud_composite(air, normalize(position), length(position))
        + ss_visible_light_air(input.uv, length(position));
    return vec4<f32>(result, 1.0);
}
