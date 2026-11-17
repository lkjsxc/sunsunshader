// SPDX-License-Identifier: Apache-2.0
// The cloud volume and its shade use the same world-space density.
const SS_CLOUD_BASE: f32 = 172.0;
const SS_CLOUD_TOP: f32 = 310.0;
const SS_CLOUD_HEIGHT: f32 = SS_CLOUD_TOP - SS_CLOUD_BASE;

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
    var broad = 0.5;
    if broad_weight > 0.001 {
        broad = mix(0.5, ss_noise3(position * vec3<f32>(0.0041, 0.011, 0.0041) + drift), broad_weight);
    }
    let threshold = mix(0.64, 0.36, frame.rain);
    if broad < threshold - 0.21 {
        return 0.0;
    }
    let detail_weight = 1.0 - smoothstep(25.0, 85.0, footprint);
    var detail = 0.5;
    if detail_weight > 0.001 {
        detail = mix(0.5, ss_noise3(position * vec3<f32>(0.013, 0.026, 0.013) + drift * 2.1), detail_weight);
    }
    let mass = smoothstep(threshold, threshold + 0.19, broad + detail * 0.21);
    return mass * layer * 0.70;
}

fn ss_cloud_density(position: vec3<f32>) -> f32 {
    return ss_cloud_density_filtered(position, 0.0);
}

fn ss_cloud_transmittance(position: vec3<f32>) -> f32 {
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

fn ss_cloud_volume(ray: vec3<f32>, behind: vec3<f32>, origin_world: vec3<f32>, max_distance: f32) -> vec3<f32> {
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
