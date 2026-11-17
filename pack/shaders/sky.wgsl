// SPDX-License-Identifier: Apache-2.0
// Original sky detail for Sunsun Shader. Atmosphere is shared with surface fog.

fn ss_star_layer(ray: vec3<f32>, density: f32, seed: i32) -> vec3<f32> {
    let absolute = abs(ray);
    var projected = ray.xy / max(absolute.z, 0.0001);
    var face = select(5i, 4i, ray.z > 0.0);
    if absolute.x >= absolute.y && absolute.x >= absolute.z {
        projected = ray.zy / absolute.x;
        face = select(1i, 0i, ray.x > 0.0);
    } else if absolute.y >= absolute.z {
        projected = ray.xz / absolute.y;
        face = select(3i, 2i, ray.y > 0.0);
    }
    let coordinate = projected * density;
    let cell = vec3<i32>(vec2<i32>(floor(coordinate)), face + seed);
    let lottery = ss_hash3(cell);
    let band_axis = normalize(vec3<f32>(0.32, 0.78, -0.54));
    let band = exp(-pow(dot(ray, band_axis) / 0.16, 2.0));
    let presence = smoothstep(0.992 - band * 0.004, 0.999, lottery);
    let jitter = vec2<f32>(ss_hash3(cell + vec3<i32>(71, 13, 0)),
        ss_hash3(cell + vec3<i32>(11, 89, 0)));
    let centre = 0.15 + jitter * 0.70;
    let offset = fract(coordinate) - centre;
    let radius = mix(0.050, 0.130, ss_hash3(cell + vec3<i32>(19, 31, 0)));
    let pixel = max(length(fwidth(coordinate)) * 0.48, 0.025);
    let core = 1.0 - smoothstep(max(radius - pixel, 0.0), radius + pixel, length(offset));
    let energy = min(1.0, radius * radius / (pixel * pixel));
    let temperature = ss_hash3(cell + vec3<i32>(7, 47, 0));
    let colour = mix(vec3<f32>(0.72, 0.83, 1.0), vec3<f32>(1.0, 0.82, 0.64), temperature);
    return colour * core * energy * presence * 4.6;
}

fn ss_starfield(ray: vec3<f32>) -> vec3<f32> {
    let visibility = (1.0 - smoothstep(-0.16, -0.035, frame.sun_direction.y))
        * (1.0 - frame.rain) * smoothstep(-0.02, 0.18, ray.y);
    let band_axis = normalize(vec3<f32>(0.32, 0.78, -0.54));
    let band = exp(-pow(dot(ray, band_axis) / 0.12, 2.0));
    let dust = ss_fractal3(ray * 43.0 + vec3<f32>(4.0, 11.0, 29.0));
    let haze = vec3<f32>(0.0035, 0.004, 0.0065) * band * (0.3 + dust);
    let stars = ss_star_layer(ray, 230.0, 0)
        + ss_star_layer(normalize(ray + vec3<f32>(0.013, 0.021, -0.008)), 415.0, 19);
    return (stars + haze) * visibility;
}

fn ss_sun_disc(ray: vec3<f32>) -> vec3<f32> {
    let angular_distance = length(cross(ray, frame.sun_direction));
    let radius = 0.007;
    let pixel = max(length(fwidth(ray)) * 0.5, 0.00015);
    let disc = 1.0 - smoothstep(radius - pixel, radius + pixel, angular_distance);
    let facing = smoothstep(0.0, 0.1, dot(ray, frame.sun_direction));
    let horizon = smoothstep(-0.015, 0.005, ray.y);
    return ss_sun_color() * disc * facing * horizon * 11.0
        * (1.0 - frame.rain * 0.86) * (1.0 - frame.thunder * 0.65);
}

// Original volume transport for Sunsun Shader.
// Beer-Lambert extinction integrated front-to-back through a finite layer;
// phase scattering follows Henyey and Greenstein (1941), cited in atmosphere.wgsl.

// A slow, repeating activity envelope varies between successive cold nights.
fn ss_aurora_activity() -> f32 {
    let phase = frame.time * (SS_TAU / 900.0);
    let cycle = 0.5 + 0.5 * cos(phase - 0.45);
    return smoothstep(0.55, 0.92, cycle);
}

fn ss_aurora(ray: vec3<f32>) -> vec3<f32> {
    if !weather_detail { return vec3<f32>(0.0); }
    let night = 1.0 - smoothstep(-0.17, -0.06, frame.sun_direction.y);
    let cold = 1.0 - smoothstep(-0.10, 0.15, frame.temperature);
    let clear = 1.0 - frame.rain;
    let visibility = night * cold * clear * ss_aurora_activity() * smoothstep(0.02, 0.20, ray.y)
        * smoothstep(-0.15, 0.45, -ray.z);
    if visibility <= 0.001 {
        return vec3<f32>(0.0);
    }
    let angle = atan2(ray.x, -ray.z);
    let drift = ss_periodic_drift(vec2<f32>(0.009, 0.0)).x;
    let fold = sin(angle * 6.0 + drift) * 0.065
        + sin(angle * 13.0 - drift * 0.7) * 0.025;
    let elevation = asin(clamp(ray.y, -1.0, 1.0));
    let base = 0.31 + fold;
    let curtain = exp(-max(elevation - base, 0.0) * 8.0)
        * smoothstep(base - 0.025, base + 0.015, elevation);
    let fibers = 0.48 + 0.52 * ss_noise3(vec3<f32>(angle * 34.0, drift * 0.2, 14.0));
    let gap = smoothstep(0.28, 0.70, ss_noise3(vec3<f32>(angle * 2.1, drift * 0.15, 33.0)));
    let tip = smoothstep(0.0, 0.35, elevation - base);
    let colour = mix(vec3<f32>(0.003, 0.016, 0.011), vec3<f32>(0.012, 0.005, 0.017), tip);
    return colour * curtain * fibers * gap * visibility;
}

fn ss_rainbow(ray: vec3<f32>) -> vec3<f32> {
    if !weather_detail { return vec3<f32>(0.0); }
    let moisture = ss_saturate((frame.wetness - frame.rain) * 2.7)
        * (1.0 - frame.rain * 0.8);
    let low_sun = smoothstep(0.015, 0.12, frame.sun_direction.y)
        * (1.0 - smoothstep(0.48, 0.70, frame.sun_direction.y));
    let above = smoothstep(0.005, 0.045, ray.y);
    let angle = acos(clamp(dot(ray, -frame.sun_direction), -1.0, 1.0));
    let radii = vec3<f32>(0.741, 0.727, 0.714);
    let bands = exp(-pow((vec3<f32>(angle) - radii) / 0.010, vec3<f32>(2.0)));
    return bands * vec3<f32>(0.040, 0.033, 0.026) * moisture * low_sun * above;
}

fn sky(input: SkyInput) -> vec4<f32> {
    let ray = normalize(input.direction);
    let colour = ss_atmosphere(ray) + ss_starfield(ray) + ss_sun_disc(ray) + ss_aurora(ray) + ss_rainbow(ray);
    // Horizon retains its moon, including the game's phase texture.
    return vec4<f32>(ss_encode(colour), 1.0);
}
