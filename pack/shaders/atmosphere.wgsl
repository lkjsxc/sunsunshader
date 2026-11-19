// SPDX-License-Identifier: Apache-2.0
// Original atmospheric approximation for Sunsun Shader.
// Physical basis: Bruneton and Neyret, "Precomputed Atmospheric Scattering"
// (2008), section 2: wavelength-dependent Rayleigh extinction and aerosol
// scattering. This is an analytic fit, not that paper's lookup-table method.
// Aerosol phase: Henyey and Greenstein, "Diffuse Radiation in the Galaxy" (1941).

const SS_PI: f32 = 3.14159265359;
const SS_TAU: f32 = 6.28318530718;

fn ss_saturate(x: f32) -> f32 {
    return clamp(x, 0.0, 1.0);
}

// Frame.time wraps each hour. A closed wind path has the requested initial
// velocity and meets itself with the same velocity at that boundary.
fn ss_periodic_drift(velocity: vec2<f32>) -> vec2<f32> {
    let seconds_per_radian = 3600.0 / SS_TAU;
    let angle = frame.time / seconds_per_radian;
    let perpendicular = vec2<f32>(-velocity.y, velocity.x);
    return seconds_per_radian * (velocity * sin(angle) + perpendicular * (1.0 - cos(angle)));
}

fn ss_hash3(cell: vec3<i32>) -> f32 {
    let p = bitcast<vec3<u32>>(cell);
    var h = p.x * 501125321u + p.y * 1136930381u + p.z * 1720413743u;
    h = (h ^ (h >> 15u)) * 1883322837u;
    h = (h ^ (h >> 13u)) * 3717610157u;
    return f32(h ^ (h >> 16u)) * (1.0 / 4294967296.0);
}

fn ss_noise3(position: vec3<f32>) -> f32 {
    let cell = vec3<i32>(floor(position));
    let f = fract(position);
    let w = f * f * (3.0 - 2.0 * f);
    let z0 = mix(
        mix(ss_hash3(cell), ss_hash3(cell + vec3<i32>(1, 0, 0)), w.x),
        mix(ss_hash3(cell + vec3<i32>(0, 1, 0)), ss_hash3(cell + vec3<i32>(1, 1, 0)), w.x),
        w.y
    );
    let z1 = mix(
        mix(ss_hash3(cell + vec3<i32>(0, 0, 1)), ss_hash3(cell + vec3<i32>(1, 0, 1)), w.x),
        mix(ss_hash3(cell + vec3<i32>(0, 1, 1)), ss_hash3(cell + vec3<i32>(1, 1, 1)), w.x),
        w.y
    );
    return mix(z0, z1, w.z);
}

fn ss_fractal3(position: vec3<f32>) -> f32 {
    return ss_noise3(position) * 0.57
        + ss_noise3(position * 2.03 + vec3<f32>(17.3, 9.1, 31.7)) * 0.28
        + ss_noise3(position * 4.19 + vec3<f32>(43.1, 12.8, 5.6)) * 0.15;
}

// A finite horizon column accounts for the atmosphere's curvature.
fn ss_air_column(elevation: f32) -> f32 {
    let above = max(elevation, 0.0);
    return inverseSqrt(above * above + 0.0016);
}

fn ss_daylight() -> f32 {
    return smoothstep(-0.065, 0.09, frame.sun_direction.y);
}

fn ss_moonlight() -> f32 {
    return smoothstep(-0.035, 0.16, frame.moon_direction.y)
        * (1.0 - smoothstep(-0.13, 0.015, frame.sun_direction.y))
        * (1.0 - 0.7 * frame.rain);
}

// Unit red-channel irradiance; visibility is supplied by ss_daylight.
fn ss_sun_color() -> vec3<f32> {
    let column = ss_air_column(frame.sun_direction.y);
    let transmission = exp(-vec3<f32>(0.045, 0.105, 0.255) * column * 0.56);
    let direct = transmission / max(transmission.r, 0.0001);
    return mix(direct * vec3<f32>(1.0, 0.965, 0.915), vec3<f32>(0.66, 0.71, 0.76), frame.rain * 0.72);
}

fn ss_phase_rayleigh(cosine: f32) -> f32 {
    return (3.0 / (16.0 * SS_PI)) * (1.0 + cosine * cosine);
}

fn ss_phase_aerosol(cosine: f32, asymmetry: f32) -> f32 {
    let denominator = max(1.0 + asymmetry * asymmetry - 2.0 * asymmetry * cosine, 0.015);
    return (1.0 - asymmetry * asymmetry) / (4.0 * SS_PI * denominator * sqrt(denominator));
}

// Continuous, unoccluded atmospheric radiance. Shared by sky, air and water.
fn ss_atmosphere(direction: vec3<f32>) -> vec3<f32> {
    let ray = normalize(direction);
    let elevation = max(ray.y, 0.0);
    let solar_height = frame.sun_direction.y;
    let solar_cosine = clamp(dot(ray, frame.sun_direction), -1.0, 1.0);
    let view_column = ss_air_column(elevation);
    let solar_column = ss_air_column(solar_height);
    let altitude = max(frame.camera_position.y - 64.0, 0.0);
    let rayleigh = vec3<f32>(0.045, 0.105, 0.255) * exp(-altitude / 8000.0);
    let aerosol = vec3<f32>(0.014 + frame.wetness * 0.026) * exp(-altitude / 1400.0);
    let extinction = rayleigh + aerosol;
    let transmission = exp(-extinction * view_column);
    let solar_transmission = exp(-extinction * solar_column * 0.52);
    let scatter = (rayleigh * ss_phase_rayleigh(solar_cosine)
        + aerosol * ss_phase_aerosol(solar_cosine, 0.72)) / extinction;
    let sunlight = smoothstep(-0.16, 0.04, solar_height);
    var colour = 10.5 * solar_transmission * scatter * (vec3<f32>(1.0) - transmission) * sunlight;

    // A broad diffuse term softens the horizon after multiple scattering.
    let horizon = pow(1.0 - elevation, 4.0);
    let diffuse_day = smoothstep(-0.1, 0.2, solar_height);
    colour += vec3<f32>(0.045, 0.085, 0.16) * horizon * diffuse_day;
    colour += vec3<f32>(0.016, 0.035, 0.062) * diffuse_day;

    // Clear air keeps a wavelength-dependent blue horizon. At high sun the
    // finite-column fit is blended with a diffuse sky fit rather than a white
    // multiple-scattering pedestal. The forward aerosol lobe stays directional.
    let clear_day = smoothstep(0.10, 0.44, solar_height) * (1.0 - frame.rain);
    let blue_gradient = mix(vec3<f32>(0.120, 0.280, 0.550),
        vec3<f32>(0.021, 0.095, 0.300), pow(elevation, 0.48));
    let aureole = ss_phase_aerosol(solar_cosine, 0.78) * 0.025
        * ss_sun_color() * smoothstep(0.0, 0.20, solar_height);
    colour = mix(colour, blue_gradient + aureole, clear_day * 0.90);

    // Long paths through the Earth's shadow retain a rose belt and violet air.
    let twilight = exp(-pow((solar_height + 0.045) / 0.16, 2.0));
    let opposite = pow(max(-solar_cosine, 0.0), 1.7);
    let rose_belt = exp(-pow((ray.y - 0.10) / 0.18, 2.0)) * opposite;
    colour += twilight * (vec3<f32>(0.11, 0.027, 0.037) * rose_belt
        + vec3<f32>(0.022, 0.016, 0.059) * (0.3 + 0.7 * elevation));

    let night = 1.0 - smoothstep(-0.16, -0.015, solar_height);
    let night_air = mix(vec3<f32>(0.00030, 0.00065, 0.0018),
        vec3<f32>(0.00012, 0.00030, 0.0011), pow(elevation, 0.45));
    colour += night_air * night;

    // Storm light is broad and subdued. Reusing the bright clear-air forward
    // lobe as a grey value makes rain a white curtain at the horizon.
    let storm_gradient = mix(vec3<f32>(0.180, 0.230, 0.300),
        vec3<f32>(0.085, 0.120, 0.170), pow(elevation, 0.40));
    let overcast = storm_gradient * diffuse_day + night_air * night * 0.55;
    colour = mix(colour, overcast, frame.rain * 0.92);
    colour *= 1.0 - 0.43 * frame.thunder;
    return max(colour, vec3<f32>(0.0));
}

// The engine does not invoke sky in these dimensions. The post pass uses this.
fn ss_dimension_sky(direction: vec3<f32>) -> vec3<f32> {
    let ray = normalize(direction);
    if frame.dimension == -1 {
        let drift = ss_periodic_drift(vec2<f32>(0.0, 0.0015));
        let ash = ss_noise3(ray * 4.0 + vec3<f32>(drift.x, 0.0, drift.y));
        return frame.fog_color * (0.60 + 0.20 * ash) + vec3<f32>(0.014, 0.004, 0.0015);
    }
    if frame.dimension == 1 {
        let ribbon = exp(-pow((ray.y + 0.22 * ray.x - 0.08) / 0.22, 2.0));
        let nebula = ss_fractal3(ray * 5.0 + vec3<f32>(13.0, 7.0, 21.0));
        return vec3<f32>(0.006, 0.003, 0.014)
            + vec3<f32>(0.020, 0.009, 0.037) * ribbon * nebula;
    }
    return ss_atmosphere(ray);
}
