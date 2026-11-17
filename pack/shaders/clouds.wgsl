// SPDX-License-Identifier: Apache-2.0
// Original cloud volumes for Sunsun Shader. Analytic support intervals keep the
// silhouettes continuous; world-space erosion breaks their edges at two scales.
// Transport uses Beer-Lambert extinction and the Henyey-Greenstein phase
// function (Henyey and Greenstein, 1941), implemented here without source reuse.
const SS_CLOUD_BASE: f32 = 172.0;
const SS_CLOUD_TOP: f32 = 310.0;
const SS_CLOUD_HEIGHT: f32 = SS_CLOUD_TOP - SS_CLOUD_BASE;

const SS_CUMULUS_CELL: f32 = 400.0;
const SS_CUMULUS_BOTTOM: f32 = 184.0;
const SS_CUMULUS_TOP: f32 = 440.0;
struct SSCumulusLobe {
    centre: vec3<f32>,
    radius: vec3<f32>,
    base: f32,
    feather: f32,
}

fn ss_cumulus_seed(cell: vec2<i32>) -> vec4<f32> {
    return vec4<f32>(ss_hash3(vec3<i32>(cell, 73)),
        ss_hash3(vec3<i32>(cell, 151)), ss_hash3(vec3<i32>(cell, 239)),
        ss_hash3(vec3<i32>(cell, 311)));
}

fn ss_cumulus_base(seed: vec4<f32>) -> f32 {
    return 188.0 + seed.z * 54.0;
}

fn ss_cumulus_count(seed: vec4<f32>) -> u32 {
    return 3u + u32(seed.x > 0.18) + u32(seed.x > 0.57);
}

// Independently varied radii, lift and horizontal offset prevent the same
// three-bump outline from recurring. Clouds occupy their own cells, but their
// centres, altitude and scale are not tied to the visible grid.
fn ss_cumulus_lobe(cell: vec2<i32>, seed: vec4<f32>, index: u32) -> SSCumulusLobe {
    let random = vec3<f32>(
        ss_hash3(vec3<i32>(cell, 397 + i32(index) * 71)),
        ss_hash3(vec3<i32>(cell, 433 + i32(index) * 113)),
        ss_hash3(vec3<i32>(cell, 487 + i32(index) * 181)));
    let centre = vec3<f32>((vec2<f32>(cell) + 0.5) * SS_CUMULUS_CELL, 0.0).xzy;
    let jitter = (seed.xy - vec2<f32>(0.5)) * 66.0;
    let scale = 0.44 + seed.w * 0.72;
    // Vertical development is independent of width and lobe occupancy.
    // The same family can be a shallow broken fragment or a rising tower.
    let development = ss_hash3(vec3<i32>(cell, 617));
    let vertical_scale = mix(0.42, 1.48, smoothstep(0.10, 0.92, development));
    let axis = normalize(seed.xy - vec2<f32>(0.5) + vec2<f32>(0.001, 0.0));
    var offset = vec2<f32>(0.0);
    var radius = vec3<f32>(100.0, 46.0, 81.0);
    var lift = 0.48;
    if index == 1u {
        offset = vec2<f32>(-60.0, -12.0);
        radius = vec3<f32>(66.0, 55.0, 60.0);
        lift = 0.61;
    }
    if index == 2u {
        offset = vec2<f32>(47.0, 23.0);
        radius = vec3<f32>(75.0, 67.0, 59.0);
        lift = 0.78;
    }
    if index == 3u {
        offset = vec2<f32>(12.0, -48.0);
        radius = vec3<f32>(56.0, 42.0, 66.0);
        lift = 0.44;
    }
    if index == 4u {
        offset = vec2<f32>(-12.0, 18.0);
        radius = vec3<f32>(58.0, 84.0, 54.0);
        lift = 1.08;
    }
    offset += (random.xz - vec2<f32>(0.5)) * 28.0;
    let turned = vec2<f32>(offset.x * axis.x - offset.y * axis.y,
        offset.x * axis.y + offset.y * axis.x) * scale + jitter;
    radius *= scale * (0.78 + random * 0.42);
    let width_scale = mix(0.76, 1.0, smoothstep(0.08, 0.65, development));
    radius *= vec3<f32>(width_scale, 1.0, width_scale);
    radius.y *= (0.72 + seed.y * 0.58) * vertical_scale;
    // Keep every support inside its traversal cell, including jitter.
    radius.x = min(radius.x, 197.0 - abs(turned.x));
    radius.z = min(radius.z, 197.0 - abs(turned.y));
    let base = ss_cumulus_base(seed) + (random.y - 0.5) * 16.0;
    radius.y = min(radius.y, (SS_CUMULUS_TOP - 4.0 - base) / (1.0 + lift));
    return SSCumulusLobe(centre + vec3<f32>(turned.x, base + lift * radius.y, turned.y),
        radius, base, 11.0 + random.x * 9.0);
}

// Approximate spatial convolution of a parabolic lobe by one finite cone.
// The normalized density (1-r^2) has diagonal second moment R_i^2/7.
// A uniform circular footprint of diameter D has transverse variance D^2/16.
// Match those moments, then preserve the untruncated lobe's density integral.
// Off-diagonal covariance and the clipped base are approximations. Bounding the
// widened support to the existing cell preserves the traversal's culling.
fn ss_cumulus_cone_lobe(lobe: SSCumulusLobe, cell: vec2<i32>,
    origin: vec3<f32>, ray: vec3<f32>, angular_diameter: f32) -> SSCumulusLobe {
    let distance = max(dot(lobe.centre - origin, ray), 0.0);
    let diameter = distance * angular_diameter;
    let added = (7.0 / 16.0) * diameter * diameter
        * max(vec3<f32>(1.0) - ray * ray, vec3<f32>(0.0));
    let cell_centre = (vec2<f32>(cell) + 0.5) * SS_CUMULUS_CELL;
    let horizontal_limit = vec2<f32>(197.0) - abs(lobe.centre.xz - cell_centre);
    let limit = vec3<f32>(horizontal_limit.x,
        SS_CUMULUS_TOP - 4.0 - lobe.centre.y, horizontal_limit.y);
    let radius = min(sqrt(lobe.radius * lobe.radius + added), max(limit, lobe.radius));
    // Preserve the midpoint of the original base transition while softening it.
    // Its lower edge remains inside the common vertical slab.
    let base_midpoint = lobe.base + lobe.feather * 0.5;
    let base_limit = max(lobe.feather, 2.0 * (base_midpoint - SS_CUMULUS_BOTTOM - 3.0));
    let feather = min(sqrt(lobe.feather * lobe.feather + added.y * (36.0 / 7.0)),
        base_limit);
    return SSCumulusLobe(lobe.centre, radius, base_midpoint - feather * 0.5, feather);
}

fn ss_cumulus_cone_mass(original: SSCumulusLobe, filtered: SSCumulusLobe) -> f32 {
    return (original.radius.x * original.radius.y * original.radius.z)
        / max(filtered.radius.x * filtered.radius.y * filtered.radius.z, 0.001);
}

fn ss_cumulus_integral(depth: f32, a: f32, n: f32, f: f32) -> f32 {
    return depth * (f - n) - a * (f * f * f - n * n * n) / 3.0;
}

fn ss_cumulus_feather_integral(depth: f32, a: f32, n: f32, f: f32,
    intercept: f32, slope: f32) -> f32 {
    let first_moment = depth * (f * f - n * n) * 0.5
        - a * (f * f * f * f - n * n * n * n) * 0.25;
    return intercept * ss_cumulus_integral(depth, a, n, f) + slope * first_moment;
}

// Coarse support and exact mass. Empty supports cost no density evaluations.
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
    let feather = lobe.feather;
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

// The erosion is evaluated in the same advected world for the picture and its
// shadow. Frequencies smaller than a distant pixel are attenuated, so fine
// cloud edges do not crawl when a player pans. No screen-space noise is used.
fn ss_cumulus_density(lobe: SSCumulusLobe, point: vec3<f32>, footprint: f32) -> f32 {
    let local = (point - lobe.centre) / lobe.radius;
    let support = 1.0 - dot(local, local);
    if support <= 0.0 { return 0.0; }
    let broad_weight = 1.0 - smoothstep(8.0, 30.0, footprint);
    var broad = 0.5;
    if broad_weight > 0.001 {
        broad = mix(0.5, ss_noise3(point * 0.045 + vec3<f32>(17.1, 3.7, 41.3)), broad_weight);
    }
    let fine_weight = 1.0 - smoothstep(4.0, 13.0, footprint);
    var fine = 0.5;
    if fine_weight > 0.001 {
        fine = mix(0.5, ss_noise3(point * 0.112 + vec3<f32>(31.7, 11.3, 7.9)), fine_weight);
    }
    var erosion = 0.49 - broad * 0.64 + (0.5 - fine) * 0.30;
    if quality >= 2u && footprint < 5.0 {
        let fringe = ss_noise3(point * 0.235 + vec3<f32>(9.1, 53.7, 2.3));
        erosion += (0.5 - fringe) * 0.10 * (1.0 - smoothstep(1.5, 5.0, footprint));
    }
    let feather = smoothstep(0.0, lobe.feather, point.y - lobe.base);
    return max(support - clamp(erosion, 0.015, 0.49), 0.0) * feather;
}

fn ss_cumulus_eroded_chord(lobe: SSCumulusLobe, origin: vec3<f32>, ray: vec3<f32>,
    start: f32, finish: f32, distant_filter: bool, sample_cap: u32, angular_cone: f32) -> vec3<f32> {
    let chord = ss_cumulus_chord(lobe, origin, ray, start, finish);
    if chord.z <= 0.0001 { return chord; }
    var samples = 3u;
    if quality == 0u { samples = 2u; }
    if quality >= 2u { samples = 5u; }
    samples = min(samples, sample_cap);
    let length = chord.y - chord.x;
    let footprint = select(0.5, max(chord.x, 0.0) * angular_cone, distant_filter);
    var mass = 0.0;
    for (var i = 0u; i < 5u; i += 1u) {
        if i >= samples { break; }
        let distance = mix(chord.x, chord.y, (f32(i) + 0.5) / f32(samples));
        mass += ss_cumulus_density(lobe, origin + ray * distance, footprint);
    }
    // The exact smooth support caps quadrature overshoot in a thin chord.
    mass = min(mass * length / f32(samples), chord.z);
    return vec3<f32>(chord.xy, mass);
}

fn ss_cumulus_origin(world: vec3<f32>) -> vec3<f32> {
    let wind = ss_periodic_drift(vec2<f32>(0.29, 0.11));
    return world - vec3<f32>(wind.x, 0.0, wind.y);
}

fn ss_cumulus_shade(position: vec3<f32>) -> f32 {
    let light = ss_light_direction();
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
        if start >= finish || mass > 160.0 { break; }
        let seed = ss_cumulus_seed(cell);
        if seed.z >= 0.30 {
            for (var i = 0u; i < 5u; i += 1u) {
                if i >= ss_cumulus_count(seed) { break; }
                mass += ss_cumulus_eroded_chord(ss_cumulus_lobe(cell, seed, i),
                    origin, light, start, finish, false, 2u, 0.0).z;
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
    return mix(1.0, exp(-mass * 0.037), shadow_weight);
}

fn ss_cumulus_transport(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>,
    max_distance: f32, reflected: bool, angular_cone: f32) -> vec3<f32> {
    let origin = ss_cumulus_origin(origin_world);
    var count = 14u;
    var range = 2900.0;
    if quality == 0u { count = 8u; range = 1400.0; }
    if quality >= 2u { count = 22u; range = 5100.0; }
    if quality >= 3u { count = 28u; range = 6600.0; }
    var sample_cap = 5u;
    if reflected {
        count = 10u; range = 1800.0; sample_cap = 2u;
        if quality >= 2u { count = 16u; range = 3500.0; sample_cap = 3u; }
    }
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
    let ambient = mix(vec3<f32>(0.002, 0.0045, 0.011),
        vec3<f32>(0.135, 0.200, 0.30), smoothstep(-0.16, 0.20, frame.sun_direction.y));
    let moon_colour = vec3<f32>(0.022, 0.038, 0.075) * ss_moonlight();
    let light = select(frame.moon_direction, frame.sun_direction, sunlit > 0.05);
    let forward = pow(max(dot(ray, frame.sun_direction), 0.0), 12.0);
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
        if seed.z >= 0.30 {
            var mass = 0.0;
            var weighted_front = 0.0;
            var weighted_resolved = 0.0;
            var weighted_bulk_depth = 0.0;
            for (var i = 0u; i < 5u; i += 1u) {
                if i >= ss_cumulus_count(seed) { break; }
                let original = ss_cumulus_lobe(cell, seed, i);
                var lobe = original;
                if reflected { lobe = ss_cumulus_cone_lobe(original, cell, origin, ray, angular_cone); }
                let chord = ss_cumulus_eroded_chord(lobe,
                    origin, ray, start, finish, true, sample_cap, angular_cone);
                let normalization = ss_cumulus_cone_mass(original, lobe);
                let filtered_mass = chord.z * normalization;
                mass += filtered_mass;
                weighted_front += mix(chord.x, chord.y, 0.31) * filtered_mass;
                if reflected && filtered_mass > 0.0001 {
                    // A broadened support does not resolve its original rim or
                    // point self-shadow. Filter radiance as well as density.
                    weighted_resolved += filtered_mass * smoothstep(0.30, 0.90, normalization);
                    // Mean column mass of a parabolic ellipsoid is 8/15 of
                    // its light-direction half extent. Its depth integral
                    // below supplies a bounded bulk-light response.
                    let light_axis = light / original.radius;
                    let mean_column = (8.0 / 15.0) / sqrt(dot(light_axis, light_axis));
                    weighted_bulk_depth += filtered_mass * mean_column * (0.036 * 0.72);
                }
            }
            if mass > 0.001 {
                let distance = weighted_front / mass;
                let point = origin + ray * distance;
                let resolved = select(1.0, clamp(weighted_resolved / mass, 0.0, 1.0), reflected);
                var light_mass = 0.0;
                if resolved > 0.001 {
                    for (var i = 0u; i < 5u; i += 1u) {
                        if i >= ss_cumulus_count(seed) { break; }
                        let original = ss_cumulus_lobe(cell, seed, i);
                        var lobe = original;
                        if reflected { lobe = ss_cumulus_cone_lobe(original, cell, origin, ray, angular_cone); }
                        light_mass += ss_cumulus_chord(lobe,
                            point, light, 0.0, 1000.0).z * 0.72 * ss_cumulus_cone_mass(original, lobe);
                    }
                }
                var lit = exp(-light_mass * 0.036);
                if reflected {
                    let optical_depth = max(weighted_bulk_depth / mass, 0.0001);
                    // Integral of exp(-t) over a finite representative column.
                    // Averaging this nonlinear response fills unresolved cloud
                    // masses instead of enlarging their bright boundary shells.
                    let bulk_light = (1.0 - exp(-optical_depth)) / optical_depth;
                    lit = mix(bulk_light, lit, resolved);
                }
                let height = ss_saturate((point.y - ss_cumulus_base(seed)) / 135.0);
                let thin_rim = exp(-mass * 0.027) * (1.0 - exp(-mass * 0.20));
                let source = ambient * (0.65 + 0.65 * height)
                    + (sun_colour * (0.055 + lit * 1.25) + moon_colour * (0.18 + lit * 0.82))
                    // A rim belongs to the illuminated flank, not the entire
                    // lower silhouette of an otherwise shaded cloud.
                    + sun_colour * forward * thin_rim * resolved
                        * (0.15 + 0.85 * sqrt(lit)) * (0.70 + dusk * 0.25)
                    + sun_colour * dusk * (1.0 - height) * 0.045;
                let air_mix = 1.0 - exp(-max(distance - 700.0, 0.0) / 5200.0);
                let fade = 1.0 - smoothstep(range * 0.72, range, distance);
                let opacity = (1.0 - exp(-mass * 0.052)) * fade;
                radiance += mix(source, air, air_mix) * opacity * transmission;
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

fn ss_cumulus_volume(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>,
    max_distance: f32) -> vec3<f32> {
    let pixel_angle = 2.0 / max(frame.resolution.y * abs(frame.projection[1].y), 1.0);
    return ss_cumulus_transport(ray, behind, origin_world, max_distance, false, pixel_angle);
}

// Water uses the same geometry, erosion and lighting with a shorter traversal
// and fewer within-lobe samples. The range fades continuously, avoiding a hard
// reflected-cloud edge. This does not create an unrelated reflection sky.
fn ss_cloud_reflection(background: vec3<f32>, direction: vec3<f32>, origin_world: vec3<f32>, angular_cone: f32) -> vec3<f32> {
    if !clouds || frame.dimension != 0 { return background; }
    let ray = normalize(direction);
    let pixel_angle = 2.0 / max(frame.resolution.y * abs(frame.projection[1].y), 1.0);
    let cone = max(angular_cone, pixel_angle);
    let high_layer = ss_cirrus_filtered(ray, background, origin_world, 11000.0, cone);
    let storm = smoothstep(0.02, 0.65, frame.rain);
    if storm <= 0.0 { return ss_cumulus_transport(ray, high_layer, origin_world, 100000.0, true, cone); }
    if storm >= 1.0 { return ss_stratus_volume(ray, high_layer, origin_world, 3500.0); }
    return mix(ss_cumulus_transport(ray, high_layer, origin_world, 100000.0, true, cone),
        ss_stratus_volume(ray, high_layer, origin_world, 3500.0), storm);
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

// Primitive of one smoothstep. The two cloud-height ramps do not overlap,
// so their difference integrates the vertical envelope exactly, without
// introducing another ray or density evaluation.
fn ss_cloud_ramp_integral(height: f32, lower: f32, upper: f32) -> f32 {
    let span = upper - lower;
    let t = clamp((height - lower) / span, 0.0, 1.0);
    return span * (t * t * t - 0.5 * t * t * t * t) + max(height - upper, 0.0);
}

fn ss_cloud_layer_integral(height: f32) -> f32 {
    return ss_cloud_ramp_integral(height, 0.0, 0.12)
        - ss_cloud_ramp_integral(height, 0.57, 1.0);
}

fn ss_cloud_density_segment(position: vec3<f32>, footprint: f32, vertical_span: f32) -> f32 {
    let base_weight = 1.0 - smoothstep(35.0, 145.0, footprint);
    var base_variation = 11.0;
    if base_weight > 0.001 {
        base_variation = mix(11.0,
            ss_noise3(vec3<f32>(position.x * 0.0035, 8.9, position.z * 0.0035)) * 22.0,
            base_weight);
    }
    let layer_height = SS_CLOUD_HEIGHT - base_variation;
    let height = (position.y - SS_CLOUD_BASE - base_variation) / layer_height;
    let half_span = max(vertical_span, 0.0) * 0.5 / layer_height;
    if height + half_span <= 0.0 || height - half_span >= 1.0 { return 0.0; }
    var layer = smoothstep(0.0, 0.12, height) * (1.0 - smoothstep(0.57, 1.0, height));
    if half_span > 0.0005 {
        layer = (ss_cloud_layer_integral(height + half_span)
            - ss_cloud_layer_integral(height - half_span)) / (2.0 * half_span);
    }
    if layer <= 0.001 { return 0.0; }
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

fn ss_cloud_density_filtered(position: vec3<f32>, footprint: f32) -> f32 {
    return ss_cloud_density_segment(position, footprint, 0.0);
}

fn ss_cloud_density(position: vec3<f32>) -> f32 {
    return ss_cloud_density_filtered(position, 0.0);
}

fn ss_stratus_transmittance(position: vec3<f32>) -> f32 {
    if !clouds || quality == 0u || frame.dimension != 0 {
        return 1.0;
    }
    let light = ss_light_direction();
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

// A separate, higher layer of sheared, broken filaments. Its mask and fibre
// phase are warped at different scales, rather than repeating parallel bands.
fn ss_cirrus_filtered(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>,
    max_distance: f32, angular_cone: f32) -> vec3<f32> {
    if abs(ray.y) <= 0.018 { return behind; }
    let distance = (510.0 - origin_world.y) / ray.y;
    if distance <= 0.0 || distance >= max_distance { return behind; }
    // Project an angular pixel/cone onto the high cloud plane. Without the
    // grazing-angle denominator, narrow fibres become horizontal one-pixel
    // stripes in the sky and bright contour loops in moving water.
    let footprint = distance * angular_cone / max(abs(ray.y), 0.018);
    let warp_weight = 1.0 - smoothstep(0.18, 0.65, footprint * 0.00292);
    let broad_weight = 1.0 - smoothstep(0.18, 0.65, footprint * 0.0038);
    let primary_weight = 1.0 - smoothstep(0.18, 0.65, footprint * 0.0095);
    let fine_weight = 1.0 - smoothstep(0.18, 0.55, footprint * 0.014);
    let point = origin_world + ray * distance;
    let wind = ss_periodic_drift(vec2<f32>(0.00012, -0.00024));
    let coordinate = vec3<f32>(point.x * 0.00065 + point.z * 0.0011 + wind.x,
        point.z * 0.0038 - point.x * 0.0008 + wind.y, 4.3);
    var warp = 0.5;
    if warp_weight > 0.001 && primary_weight > 0.001 {
        warp = mix(0.5, ss_noise3(coordinate * 0.75 + vec3<f32>(7.4, 18.2, 9.1)), warp_weight);
    }
    var broad = 0.5;
    if broad_weight > 0.001 {
        broad = mix(0.5, ss_noise3(vec3<f32>(point.x * 0.0024 + wind.x, 17.9, point.z * 0.0024 + wind.y)), broad_weight);
    }
    var primary = 0.5;
    if primary_weight > 0.001 {
        primary = mix(0.5, ss_noise3(coordinate + vec3<f32>(warp * 1.4, warp * 0.8, 0.0)), primary_weight);
    }
    var fine = 0.5;
    if fine_weight > 0.001 {
        fine = mix(0.5, ss_noise3(coordinate * vec3<f32>(1.8, 3.1, 1.0) + vec3<f32>(11.0)), fine_weight);
    }
    let fibres = primary * 0.66 + fine * 0.34;
    // An isotropic patch mask interrupts the sheared fibres, so low-sun
    // perspective cannot turn the entire high layer into long contrails.
    let amount = smoothstep(0.46, 0.72, broad) * smoothstep(0.46, 0.75, fibres) * 0.20
        * (1.0 - smoothstep(4500.0, 11000.0, distance)) * (1.0 - frame.rain * 0.85);
    let twilight_light = smoothstep(-0.23, 0.05, frame.sun_direction.y);
    let forward = pow(max(dot(ray, frame.sun_direction), 0.0), 8.0);
    let colour = ss_sun_color() * twilight_light * (0.60 + forward * 0.25)
        + vec3<f32>(0.015, 0.028, 0.054) * ss_moonlight();
    return mix(behind, colour, amount);
}

fn ss_cirrus(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>, max_distance: f32) -> vec3<f32> {
    let pixel_angle = 2.0 / max(frame.resolution.y * abs(frame.projection[1].y), 1.0);
    return ss_cirrus_filtered(ray, behind, origin_world, max_distance, pixel_angle);
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
    let phase_light = 0.30 + min(forward, 1.8) * 0.85;
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
        let pixel_angle = 2.0 / max(frame.resolution.y * abs(frame.projection[1].y), 1.0);
        let footprint = max(stride, distance * pixel_angle);
        let vertical_span = abs(ray.y) * stride;
        let density = ss_cloud_density_segment(point, footprint, vertical_span);
        if density > 0.003 {
            // The light response must resolve the same finite march segment;
            // point-sampled base/noise lighting would reintroduce horizon bands.
            var shadow_mass = ss_cloud_density_segment(point + light_direction * 28.0,
                footprint, vertical_span) * 42.0;
            if quality >= 2u {
                shadow_mass = shadow_mass * 0.65
                    + ss_cloud_density_segment(point + light_direction * 68.0,
                        footprint, vertical_span) * 46.0;
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
    if origin_world.y > 510.0 {
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
