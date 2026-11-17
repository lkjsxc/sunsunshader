// SPDX-License-Identifier: Apache-2.0
// Beer-Lambert attenuation with an analytic exponential height layer.
// The colour at the distance boundary is the same function the sky evaluates.

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
        * mix(0.18, 1.0, outside) * haze;
    let physical = 1.0 - exp(-distance * density);
    let limit = max(24.0, frame.render_distance);
    let edge_distance = max(length(position.xz), abs(position.y));
    let edge = smoothstep(limit * 0.78, limit * 0.995, edge_distance);
    return 1.0 - (1.0 - physical) * (1.0 - edge);
}

fn ss_fog(color: vec3<f32>, position: vec3<f32>) -> vec3<f32> {
    let distance = length(position);
    let direction = position / max(distance, 0.001);
    var amount = ss_air_amount(position);
    let air = ss_dimension_sky(direction);
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
        let water_light = 0.16 + 0.84 * ss_daylight();
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
