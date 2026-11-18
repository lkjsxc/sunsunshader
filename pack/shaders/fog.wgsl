// SPDX-License-Identifier: Apache-2.0
// Beer-Lambert attenuation with an analytic exponential height layer.
// The colour at the distance boundary is the same function the sky evaluates.

// The medium exists independently of emitters. Clear high sun has no added
// local mist; damp nights, low sun, rain and enclosed air carry more scatter.
fn ss_local_air_density() -> f32 {
    if !local_haze || quality == 0u || frame.in_water > 0.9 || frame.dimension != 0 { return 0.0; }
    let outside = smoothstep(0.035, 0.65, frame.eye_light_smooth.y);
    let day = ss_daylight();
    let low_sun = day * (1.0 - smoothstep(0.08, 0.34, frame.sun_direction.y));
    let damp = 0.65 + 0.35 * clamp(frame.downfall, 0.0, 1.0);
    return (0.0036 * (1.0 - outside) + 0.0018 * (1.0 - day)
        + 0.0030 * low_sun + 0.009 * frame.rain) * damp * haze;
}

fn ss_air_amount(position: vec3<f32>) -> f32 {
    let distance = length(position);
    let day = ss_daylight();
    let morning_phase = fract(frame.day_time - 0.02 + 0.5) - 0.5;
    let morning = exp(-pow(morning_phase * 12.0, 2.0));
    let camera_height = frame.camera_position.y;
    let end_height = camera_height + position.y;
    let low_layer = exp(-max((camera_height + end_height) * 0.5 - 63.0, 0.0) / 24.0);
    let outside = smoothstep(0.05, 0.75, frame.eye_light_smooth.y);
    let density = (0.00022 + 0.0038 * frame.rain
        + low_layer * (0.00024 + morning * 0.0018 + (1.0 - day) * 0.0005))
        * mix(0.18, 1.0, outside) * haze + ss_local_air_density();
    let physical = 1.0 - exp(-distance * density);
    let limit = max(24.0, frame.render_distance);
    let edge_distance = max(length(position.xz), abs(position.y));
    let edge = smoothstep(limit * 0.78, limit * 0.995, edge_distance);
    return 1.0 - (1.0 - physical) * (1.0 - edge);
}

fn ss_fog(color: vec3<f32>, position: vec3<f32>, sky_light: f32) -> vec3<f32> {
    let distance = length(position);
    let direction = position / max(distance, 0.001);
    var amount = ss_air_amount(position);
    var air = ss_dimension_sky(direction);
    if frame.dimension == 0 {
        // An enclosed ray cannot collect an unoccluded blue sky. The two
        // endpoint light levels are a conservative substitute for a sky volume.
        let open = min(clamp(sky_light, 0.0, 1.0), clamp(frame.eye_light_smooth.y, 0.0, 1.0));
        air *= smoothstep(0.03, 0.60, open);
    }
    if frame.dimension == -1 {
        amount = max(amount, 1.0 - exp(-distance * 0.020 * haze));
    }
    if frame.dimension == 1 {
        amount = max(amount, 1.0 - exp(-distance * 0.0016 * haze));
    }
    return ss_camera_fog(color, mix(color, air, amount), distance);
}

// Camera media and vision effects also cover sky rays that have no depth.
fn ss_camera_fog(color: vec3<f32>, air_result: vec3<f32>, distance: f32) -> vec3<f32> {
    var result = air_result;
    if frame.in_water > 0.001 {
        let transmission = exp(-distance * vec3<f32>(0.17, 0.055, 0.025));
        let water_light = ss_daylight() * clamp(frame.eye_light_smooth.y, 0.0, 1.0)
            + 0.018 * ss_moonlight() * pow(clamp(frame.eye_light_smooth.y, 0.0, 1.0), 2.0)
            + 0.55 * pow(clamp(frame.eye_light_smooth.x, 0.0, 1.0), 2.35);
        let underwater = color * transmission
            + vec3<f32>(0.012, 0.10, 0.14) * (vec3<f32>(1.0) - transmission) * water_light;
        result = mix(result, underwater, frame.in_water);
    }
    if frame.in_lava > 0.001 {
        result = mix(result, vec3<f32>(0.78, 0.12, 0.009), (1.0 - exp(-distance * 1.5)) * frame.in_lava);
    }
    let obscured = max(frame.blindness, frame.darkness);
    result *= 1.0 - smoothstep(2.0, 18.0, distance) * obscured * 0.96;
    if frame.eye_in == 3u {
        result = mix(result, vec3<f32>(0.60, 0.73, 0.82), smoothstep(0.2, 3.0, distance));
    }
    return result;
}
