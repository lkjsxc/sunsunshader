// SPDX-License-Identifier: Apache-2.0
// The cloud volume and its shade use the same world-space density.
const SS_CLOUD_BASE: f32 = 172.0;
const SS_CLOUD_TOP: f32 = 310.0;
const SS_CLOUD_HEIGHT: f32 = SS_CLOUD_TOP - SS_CLOUD_BASE;

// Clear-weather cumulus is an original compact analytic volume. Integrating a
// parabolic ellipsoid exactly removes height-slice contours at grazing angles.
// A cell holds three overlapping lobes; every lobe stays inside that cell.
const SS_CUMULUS_CELL: f32 = 360.0;
const SS_CUMULUS_BOTTOM: f32 = 180.0;
const SS_CUMULUS_TOP: f32 = 375.0;
struct SSCumulusLobe {
    centre: vec3<f32>,
    radius: vec3<f32>,
    base: f32,
}

fn ss_cumulus_seed(cell: vec2<i32>) -> vec4<f32> {
    return vec4<f32>(ss_hash3(vec3<i32>(cell, 73)),
        ss_hash3(vec3<i32>(cell, 151)), ss_hash3(vec3<i32>(cell, 239)),
        ss_hash3(vec3<i32>(cell, 311)));
}

fn ss_cumulus_lobe(cell: vec2<i32>, seed: vec4<f32>, index: u32) -> SSCumulusLobe {
    let centre = vec3<f32>((vec2<f32>(cell) + 0.5) * SS_CUMULUS_CELL, 0.0).xzy
        + vec3<f32>((seed.x - 0.5) * 30.0, 0.0, (seed.y - 0.5) * 30.0);
    let base = 213.0 + seed.z * 17.0;
    let scale = 0.70 + seed.w * 0.30;
    let axis = normalize(seed.xy - vec2<f32>(0.5) + vec2<f32>(0.001, 0.0));
    var offset = vec2<f32>(-56.0, -13.0);
    var radius = vec3<f32>(76.0, 60.0, 73.0);
    var lift = 0.55;
    if index == 1u {
        offset = vec2<f32>(13.0, 18.0);
        radius = vec3<f32>(85.0, 78.0, 81.0);
        lift = 0.82;
    }
    if index == 2u {
        offset = vec2<f32>(67.0, -18.0);
        radius = vec3<f32>(65.0, 56.0, 67.0);
        lift = 0.58;
    }
    radius *= scale;
    let turned = vec2<f32>(offset.x * axis.x - offset.y * axis.y,
        offset.x * axis.y + offset.y * axis.x) * scale;
    return SSCumulusLobe(centre + vec3<f32>(turned.x, base + lift * radius.y, turned.y),
        radius, base);
}

fn ss_cumulus_integral(depth: f32, a: f32, n: f32, f: f32) -> f32 {
    return depth * (f - n) - a * (f * f * f - n * n * n) / 3.0;
}

// Exact integral of the same density multiplied by a linear vertical feather.
fn ss_cumulus_feather_integral(depth: f32, a: f32, n: f32, f: f32,
    intercept: f32, slope: f32) -> f32 {
    let first_moment = depth * (f * f - n * n) * 0.5
        - a * (f * f * f * f - n * n * n * n) * 0.25;
    return intercept * ss_cumulus_integral(depth, a, n, f) + slope * first_moment;
}

// Near, far and the exact mass of a parabolic ellipsoid with a shared soft base.
// The 16-block feather reaches zero continuously: there is no hard clipping
// silhouette, marching noise, or extra volume sample at the underside.
fn ss_cumulus_chord(lobe: SSCumulusLobe, origin: vec3<f32>, ray: vec3<f32>,
    start: f32, finish: f32) -> vec3<f32> {
    let p = (origin - lobe.centre) / lobe.radius;
    let d = ray / lobe.radius;
    let a = dot(d, d);
    let middle = -dot(p, d) / a;
    let depth = 1.0 - dot(p, p) + middle * middle * a;
    if depth <= 0.0 { return vec3<f32>(0.0); }
    let half_chord = sqrt(depth / a);
    var near = max(middle - half_chord, start);
    var far = min(middle + half_chord, finish);
    if far <= near { return vec3<f32>(0.0); }
    let y_near = origin.y + ray.y * near;
    let y_far = origin.y + ray.y * far;
    if max(y_near, y_far) <= lobe.base { return vec3<f32>(0.0); }
    let feather = 16.0;
    if min(y_near, y_far) >= lobe.base + feather {
        let mass = ss_cumulus_integral(depth, a, near - middle, far - middle);
        return vec3<f32>(near, far, max(mass, 0.0));
    }
    if abs(ray.y) < 0.000001 {
        let weight = clamp((origin.y - lobe.base) / feather, 0.0, 1.0);
        let mass = ss_cumulus_integral(depth, a, near - middle, far - middle) * weight;
        return vec3<f32>(near, far, max(mass, 0.0));
    }
    let base_hit = (lobe.base - origin.y) / ray.y;
    let full_hit = (lobe.base + feather - origin.y) / ray.y;
    if ray.y > 0.0 { near = max(near, base_hit); }
    else { far = min(far, base_hit); }
    if far <= near { return vec3<f32>(0.0); }
    let ramp_near = max(near, min(base_hit, full_hit));
    let ramp_far = min(far, max(base_hit, full_hit));
    var mass = 0.0;
    if ramp_far > ramp_near {
        let intercept = (origin.y + ray.y * middle - lobe.base) / feather;
        mass = ss_cumulus_feather_integral(depth, a, ramp_near - middle,
            ramp_far - middle, intercept, ray.y / feather);
    }
    let full_near = select(near, max(near, full_hit), ray.y > 0.0);
    let full_far = select(min(far, full_hit), far, ray.y > 0.0);
    if full_far > full_near {
        mass += ss_cumulus_integral(depth, a, full_near - middle, full_far - middle);
    }
    return vec3<f32>(near, far, max(mass, 0.0));
}

fn ss_cumulus_origin(world: vec3<f32>) -> vec3<f32> {
    let wind = ss_periodic_drift(vec2<f32>(0.29, 0.11));
    return world - vec3<f32>(wind.x, 0.0, wind.y);
}

fn ss_cumulus_shade(position: vec3<f32>) -> f32 {
    let light = frame.light_direction;
    // At grazing sun angles the distant column is dominated by the air.
    // This continuous fade also bounds the shadow search to eight cells.
    let shadow_weight = smoothstep(0.14, 0.30, light.y);
    if shadow_weight <= 0.0 { return 1.0; }
    let origin = ss_cumulus_origin(position + frame.camera_position);
    var start = max((SS_CUMULUS_BOTTOM - origin.y) / light.y, 0.0);
    let finish = (SS_CUMULUS_TOP - origin.y) / light.y;
    if finish <= start { return 1.0; }
    var cell = vec2<i32>(floor((origin + light * (start + 0.001)).xz / SS_CUMULUS_CELL));
    let direction = vec2<i32>(select(vec2<f32>(-1.0), vec2<f32>(1.0), light.xz >= vec2<f32>(0.0)));
    let crossing_step = SS_CUMULUS_CELL / max(abs(light.xz), vec2<f32>(0.000001));
    let boundary = (vec2<f32>(cell)
        + select(vec2<f32>(0.0), vec2<f32>(1.0), direction > vec2<i32>(0))) * SS_CUMULUS_CELL;
    var crossing = (boundary - origin.xz)
        / select(vec2<f32>(0.000001), light.xz, abs(light.xz) > vec2<f32>(0.000001));
    var mass = 0.0;
    for (var c = 0u; c < 8u; c += 1u) {
        if start >= finish || mass > 180.0 { break; }
        let seed = ss_cumulus_seed(cell);
        if seed.z >= 0.24 {
            for (var i = 0u; i < 3u; i += 1u) {
                mass += ss_cumulus_chord(ss_cumulus_lobe(cell, seed, i),
                    origin, light, start, finish).z;
            }
        }
        if crossing.x < crossing.y {
            start = crossing.x;
            crossing.x += crossing_step.x;
            cell.x += direction.x;
        } else {
            start = crossing.y;
            crossing.y += crossing_step.y;
            cell.y += direction.y;
        }
    }
    return mix(1.0, exp(-mass * 0.028), shadow_weight);
}

fn ss_cumulus_volume(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>,
    max_distance: f32) -> vec3<f32> {
    let origin = ss_cumulus_origin(origin_world);
    var count = 12u;
    var range = 2400.0;
    if quality == 0u { count = 6u; range = 1000.0; }
    if quality == 2u { count = 18u; range = 3900.0; }
    if quality >= 3u { count = 28u; range = 6200.0; }
    // A line crosses no more than floor(range * sqrt(2) / cell) + 3
    // grid cells. The ranges above therefore finish before the traversal cap.
    var start = 0.0;
    var finish = min(max_distance, range);
    if abs(ray.y) < 0.0001 {
        if origin.y < SS_CUMULUS_BOTTOM || origin.y > SS_CUMULUS_TOP { return behind; }
    } else {
        let t0 = (SS_CUMULUS_BOTTOM - origin.y) / ray.y;
        let t1 = (SS_CUMULUS_TOP - origin.y) / ray.y;
        start = max(min(t0, t1), 0.0);
        finish = min(finish, max(t0, t1));
    }
    if finish <= start { return behind; }
    let sunlit = smoothstep(-0.18, 0.06, frame.sun_direction.y);
    let sun_colour = ss_sun_color() * sunlit * (1.0 - frame.thunder * 0.45);
    let ambient = mix(vec3<f32>(0.004, 0.008, 0.018),
        vec3<f32>(0.24, 0.33, 0.46), ss_daylight());
    let moon_colour = vec3<f32>(0.017, 0.026, 0.045) * ss_moonlight();
    let light = select(frame.moon_direction, frame.sun_direction, sunlit > 0.05);
    let phase = min(ss_phase_aerosol(dot(ray, frame.sun_direction), 0.66), 3.0);
    let dusk = (1.0 - smoothstep(0.02, 0.30, frame.sun_direction.y)) * sunlit;
    let air = ss_atmosphere(ray);
    var cell = vec2<i32>(floor((origin + ray * (start + 0.001)).xz / SS_CUMULUS_CELL));
    let direction = vec2<i32>(select(vec2<f32>(-1.0), vec2<f32>(1.0), ray.xz >= vec2<f32>(0.0)));
    let crossing_step = SS_CUMULUS_CELL / max(abs(ray.xz), vec2<f32>(0.000001));
    let boundary = (vec2<f32>(cell)
        + select(vec2<f32>(0.0), vec2<f32>(1.0), direction > vec2<i32>(0))) * SS_CUMULUS_CELL;
    var crossing = (boundary - origin.xz)
        / select(vec2<f32>(0.000001), ray.xz, abs(ray.xz) > vec2<f32>(0.000001));
    var transmission = 1.0;
    var radiance = vec3<f32>(0.0);
    for (var c = 0u; c < 28u; c += 1u) {
        if c >= count || start >= finish || transmission < 0.012 { break; }
        let seed = ss_cumulus_seed(cell);
        if seed.z >= 0.24 {
            var mass = 0.0;
            var weighted_front = 0.0;
            for (var i = 0u; i < 3u; i += 1u) {
                let chord = ss_cumulus_chord(ss_cumulus_lobe(cell, seed, i),
                    origin, ray, start, finish);
                mass += chord.z;
                weighted_front += mix(chord.x, chord.y, 0.22) * chord.z;
            }
            if mass > 0.001 {
                let distance = weighted_front / mass;
                let point = origin + ray * distance;
                var light_mass = 0.0;
                for (var i = 0u; i < 3u; i += 1u) {
                    light_mass += ss_cumulus_chord(ss_cumulus_lobe(cell, seed, i),
                        point, light, 0.0, 1000.0).z;
                }
                let lit = exp(-light_mass * 0.025);
                let height = ss_saturate((point.y - 185.0) / 175.0);
                let source = ambient * (0.65 + 0.35 * height)
                    + (sun_colour * (0.28 + lit * 0.95 + phase * 1.6) + moon_colour)
                        * (0.45 + lit * 0.55)
                    + sun_colour * dusk * (1.0 - height) * 0.13;
                let haze = 1.0 - exp(-max(distance - 550.0, 0.0) / 2600.0);
                let fade = 1.0 - smoothstep(range * 0.66, range, distance);
                let opacity = (1.0 - exp(-mass * 0.035)) * fade;
                radiance += mix(source, air, haze) * opacity * transmission;
                transmission *= 1.0 - opacity;
            }
        }
        if crossing.x < crossing.y {
            start = crossing.x;
            crossing.x += crossing_step.x;
            cell.x += direction.x;
        } else {
            start = crossing.y;
            crossing.y += crossing_step.y;
            cell.y += direction.y;
        }
    }
    return behind * transmission + radiance;
}

// Both end states keep their own inexpensive path. Intermediate rain blends
// continuously, so the cloud field does not switch at the first rain tick.
fn ss_cloud_transmittance(position: vec3<f32>) -> f32 {
    if !clouds || quality == 0u || frame.dimension != 0 { return 1.0; }
    let storm = smoothstep(0.02, 0.65, frame.rain);
    if storm <= 0.0 { return ss_cumulus_shade(position); }
    if storm >= 1.0 { return ss_stratus_transmittance(position); }
    return mix(ss_cumulus_shade(position), ss_stratus_transmittance(position), storm);
}

fn ss_cloud_volume(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>,
    max_distance: f32) -> vec3<f32> {
    let storm = smoothstep(0.02, 0.65, frame.rain);
    if storm <= 0.0 { return ss_cumulus_volume(ray, behind, origin_world, max_distance); }
    if storm >= 1.0 { return ss_stratus_volume(ray, behind, origin_world, max_distance); }
    return mix(ss_cumulus_volume(ray, behind, origin_world, max_distance),
        ss_stratus_volume(ray, behind, origin_world, max_distance), storm);
}

fn ss_cloud_density_filtered(position: vec3<f32>, footprint: f32) -> f32 {
    let height = (position.y - SS_CLOUD_BASE) / SS_CLOUD_HEIGHT;
    let layer = smoothstep(0.0, 0.12, height) * (1.0 - smoothstep(0.57, 1.0, height));
    if layer <= 0.001 {
        return 0.0;
    }
    let wind = ss_periodic_drift(vec2<f32>(0.0012, 0.00045));
    let drift = vec3<f32>(wind.x, 0.0, wind.y);
    // Average frequencies a long march segment cannot resolve. This removes
    // coherent horizon contours without adding samples or screen-space grain.
    let broad_weight = 1.0 - smoothstep(70.0, 220.0, footprint);
    let detail_weight = 1.0 - smoothstep(25.0, 85.0, footprint);
    // Filtering the noise mean alone loses clouds below the density cutoff.
    // Broaden that cutoff by the variance removed from both noise bands.
    // 0.032 is a conservative mean variance for cubic lattice value noise.
    let lost_variance = 0.032 * ((1.0 - broad_weight * broad_weight)
        + 0.21 * 0.21 * (1.0 - detail_weight * detail_weight));
    let transition = sqrt(0.19 * 0.19 + 4.0 * lost_variance);
    var broad = 0.5;
    if broad_weight > 0.001 {
        broad = mix(0.5, ss_noise3(position * 0.0041 + vec3<f32>(0.0, 1.6629, 0.0) + drift), broad_weight);
    }
    let threshold = mix(0.64, 0.36, frame.rain);
    let lower = threshold + 0.095 - transition * 0.5;
    let upper = threshold + 0.095 + transition * 0.5;
    if broad + 0.21 < lower {
        return 0.0;
    }
    var detail = 0.5;
    if detail_weight > 0.001 {
        detail = mix(0.5, ss_noise3(position * 0.013 + vec3<f32>(0.0, 3.133, 0.0) + drift * 2.1), detail_weight);
    }
    let mass = smoothstep(lower, upper, broad + detail * 0.21);
    return mass * layer * 0.70;
}

fn ss_cloud_density(position: vec3<f32>) -> f32 {
    return ss_cloud_density_filtered(position, 0.0);
}

fn ss_stratus_transmittance(position: vec3<f32>) -> f32 {
    if !clouds || quality == 0u || frame.dimension != 0 {
        return 1.0;
    }
    let light = frame.light_direction;
    if abs(light.y) < 0.015 { return 1.0; }
    let world = position + frame.camera_position;
    let first = (SS_CLOUD_BASE - world.y) / light.y;
    let last = (SS_CLOUD_TOP - world.y) / light.y;
    let start = max(min(first, last), 0.0);
    let finish = max(first, last);
    if finish <= start { return 1.0; }
    let length = finish - start;
    var density = ss_cloud_density(world + light * (start + length * 0.5));
    if quality >= 2u {
        density = 0.5 * (ss_cloud_density(world + light * (start + length * 0.25))
            + ss_cloud_density(world + light * (start + length * 0.75)));
    }
    return exp(-density * length * 0.042);
}

fn ss_cirrus(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>, max_distance: f32) -> vec3<f32> {
    if abs(ray.y) <= 0.018 {
        return behind;
    }
    let distance = (380.0 - origin_world.y) / ray.y;
    if distance <= 0.0 || distance >= max_distance { return behind; }
    let point = origin_world + ray * distance;
    let wind = ss_periodic_drift(vec2<f32>(0.00012, -0.00024));
    let stretched = vec3<f32>(point.x * 0.0008 + point.z * 0.0013 + wind.x,
        point.z * 0.0044 + wind.y, 4.3);
    let thread = ss_noise3(stretched) * 0.7 + ss_noise3(stretched * 2.1 + vec3<f32>(11.0)) * 0.3;
    let amount = smoothstep(0.56, 0.83, thread) * 0.30
        * (1.0 - smoothstep(3000.0, 9000.0, distance)) * (1.0 - frame.rain * 0.5);
    let twilight_light = smoothstep(-0.18, 0.05, frame.sun_direction.y);
    let forward = pow(max(dot(ray, frame.sun_direction), 0.0), 6.0);
    let colour = ss_sun_color() * twilight_light * (0.38 + forward * 0.5)
        + vec3<f32>(0.008, 0.013, 0.023) * ss_moonlight();
    return mix(behind, colour, amount);
}

fn ss_stratus_volume(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>, max_distance: f32) -> vec3<f32> {
    let inside = origin_world.y > SS_CLOUD_BASE && origin_world.y < SS_CLOUD_TOP;
    var start = 0.0;
    var finish = min(5500.0, max_distance);
    if abs(ray.y) < 0.0005 {
        if !inside { return behind; }
    } else {
        let t0 = (SS_CLOUD_BASE - origin_world.y) / ray.y;
        let t1 = (SS_CLOUD_TOP - origin_world.y) / ray.y;
        start = max(min(t0, t1), 0.0);
        finish = min(finish, max(t0, t1));
    }
    if finish <= start {
        return behind;
    }
    var count = 12u;
    if quality == 0u { count = 6u; }
    if quality == 2u { count = 18u; }
    if quality >= 3u { count = 28u; }
    let sunlit = smoothstep(-0.18, 0.06, frame.sun_direction.y);
    let sun_colour = ss_sun_color() * sunlit * (1.0 - frame.thunder * 0.45);
    let moon_colour = vec3<f32>(0.017, 0.026, 0.045) * ss_moonlight();
    let ambient = mix(vec3<f32>(0.0025, 0.005, 0.011), vec3<f32>(0.15, 0.20, 0.28), ss_daylight());
    let forward = ss_phase_aerosol(dot(ray, frame.sun_direction), 0.66);
    let phase_light = 0.40 + min(forward, 3.0) * 1.6;
    let light_direction = select(frame.moon_direction, frame.sun_direction, sunlit > 0.05);
    let dusk = (1.0 - smoothstep(0.02, 0.30, frame.sun_direction.y)) * sunlit;
    var transmission = 1.0;
    var radiance = vec3<f32>(0.0);
    for (var i = 0u; i < 28u; i += 1u) {
        if i >= count || transmission < 0.012 {
            break;
        }
        let near_fraction = f32(i) / f32(count);
        let far_fraction = f32(i + 1u) / f32(count);
        // Resolve nearby extinction first when the camera is inside the volume.
        let near_step = mix(near_fraction, near_fraction * near_fraction, f32(inside));
        let far_step = mix(far_fraction, far_fraction * far_fraction, f32(inside));
        let stride = (finish - start) * (far_step - near_step);
        let distance = start + (finish - start) * (near_step + far_step) * 0.5;
        let point = origin_world + ray * distance;
        let density = ss_cloud_density_filtered(point, stride);
        if density > 0.003 {
            var shadow_mass = ss_cloud_density(point + light_direction * 28.0) * 42.0;
            if quality >= 2u {
                shadow_mass = shadow_mass * 0.65
                    + ss_cloud_density(point + light_direction * 68.0) * 46.0;
            }
            let light_transmission = exp(-shadow_mass * 0.052);
            let height = ss_saturate((point.y - SS_CLOUD_BASE) / SS_CLOUD_HEIGHT);
            let bounce = sun_colour * dusk * (1.0 - height) * 0.13;
            let source = ambient * (0.48 + height * 0.52)
                + (sun_colour * phase_light + moon_colour) * light_transmission + bounce;
            let opacity = 1.0 - exp(-density * stride * 0.042);
            radiance += source * opacity * transmission;
            transmission *= 1.0 - opacity;
        }
    }
    let cloud_distance = start + (finish - start) * 0.30;
    let haze = 1.0 - exp(-max(cloud_distance - 400.0, 0.0) / 1900.0);
    let fog_colour = ss_atmosphere(ray);
    radiance = mix(radiance, fog_colour * (1.0 - transmission), haze);
    let cloud_colour = behind * transmission + radiance;
    let far_contrast = 1.0 - smoothstep(1800.0, 5400.0, start);
    return mix(behind, cloud_colour, far_contrast);
}


// Composite from far to near and stop at the first opaque scene surface.
// max_distance is camera-relative geometry distance, or a large value for sky.
fn ss_cloud_composite_from(background: vec3<f32>, direction: vec3<f32>, origin_world: vec3<f32>, max_distance: f32) -> vec3<f32> {
    if !clouds || frame.dimension != 0 || max_distance <= 0.0 {
        return background;
    }
    let ray = normalize(direction);
    var colour = background;
    if origin_world.y > 380.0 {
        colour = ss_cloud_volume(ray, colour, origin_world, max_distance);
        colour = ss_cirrus(ray, colour, origin_world, max_distance);
    } else {
        colour = ss_cirrus(ray, colour, origin_world, max_distance);
        colour = ss_cloud_volume(ray, colour, origin_world, max_distance);
    }
    return colour;
}

fn ss_cloud_composite(background: vec3<f32>, direction: vec3<f32>, max_distance: f32) -> vec3<f32> {
    return ss_cloud_composite_from(background, direction, frame.camera_position, max_distance);
}
