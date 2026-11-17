// Copyright 2026 Sunsun Shader contributors. SPDX-License-Identifier: Apache-2.0
// Water is shaded where its actual surface is drawn. Post depth has no water mask.
// Fresnel and GGX follow the equations in Walter et al.,
// "Microfacet Models for Refraction through Rough Surfaces", EGSR 2007.
// All code, wave synthesis and sampling patterns here are original.

struct SsWaterReflection {
    color: vec3<f32>,
    confidence: f32,
}

fn ss_water_hash(p: vec2<f32>) -> f32 {
    let folded = fract(p * vec2<f32>(0.1037, 0.1193));
    let mixed = folded + dot(folded, folded.yx + vec2<f32>(19.17, 37.41));
    return fract((mixed.x + mixed.y) * (mixed.x + 0.41));
}

fn ss_water_wave_normal(input: MaterialInput) -> vec3<f32> {
    if input.face != 1u || water_waves <= 0.0 {
        return input.normal;
    }
    let world = input.position + frame.camera_position;
    let p = world.xz;
    let t = frame.time;
    let a = dot(p, vec2<f32>(0.71, 0.32)) + t * 0.84;
    let b = dot(p, vec2<f32>(-0.29, 1.13)) - t * 1.02;
    let c = dot(p, vec2<f32>(1.91, -0.83)) + t * 1.42;
    let d = dot(p, vec2<f32>(-2.13, -1.57)) - t * 1.73;
    var slope = vec2<f32>(0.71, 0.32) * cos(a) * 0.044
              + vec2<f32>(-0.29, 1.13) * cos(b) * 0.027
              + vec2<f32>(1.91, -0.83) * cos(c) * 0.012
              + vec2<f32>(-2.13, -1.57) * cos(d) * 0.006;

    if frame.rain > 0.01 && frame.precipitation == 1u {
        let grid = p * 0.8;
        let cell = floor(grid);
        let h = ss_water_hash(cell);
        let centre = vec2<f32>(0.5) + (vec2<f32>(h, ss_water_hash(cell + 71.0)) - 0.5) * 0.20;
        let delta = fract(grid) - centre;
        let r = length(delta);
        let age = fract(t * 0.79 + h);
        let ring = r - age * 0.40;
        let envelope = exp(-ring * ring * 240.0) * (1.0 - age) * (1.0 - smoothstep(0.30, 0.48, r));
        slope += delta / max(r, 0.025) * cos(ring * 58.0) * envelope * frame.rain * 0.028;
    }

    // Subpixel waves flatten gradually so the far shore remains steady.
    let distance_fade = 1.0 / (1.0 + length(input.position) * 0.007);
    let upward = normalize(vec3<f32>(-slope.x * water_waves * distance_fade, 1.0,
                                     -slope.y * water_waves * distance_fade));
    return upward * select(-1.0, 1.0, input.normal.y >= 0.0);
}

fn ss_water_pixel(uv: vec2<f32>) -> vec2<i32> {
    let size = vec2<i32>(textureDimensions(opaque_depth));
    return clamp(vec2<i32>(uv * vec2<f32>(size)), vec2<i32>(0), size - vec2<i32>(1));
}

fn ss_water_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view = frame.projection_inverse * clip;
    return (frame.view_inverse * vec4<f32>(view.xyz / max(abs(view.w), 0.000001), 0.0)).xyz;
}

fn ss_water_color(uv: vec2<f32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(opaque_color));
    let pixel = clamp(uv * vec2<f32>(size) - 0.5, vec2<f32>(0.0), vec2<f32>(size - vec2<i32>(1)));
    let base = vec2<i32>(floor(pixel));
    let top = min(base + vec2<i32>(1), size - vec2<i32>(1));
    let weight = fract(pixel);
    let a = textureLoad(opaque_color, base, 0).rgb;
    let b = textureLoad(opaque_color, vec2<i32>(top.x, base.y), 0).rgb;
    let c = textureLoad(opaque_color, vec2<i32>(base.x, top.y), 0).rgb;
    let d = textureLoad(opaque_color, top, 0).rgb;
    return mix(mix(a, b, weight.x), mix(c, d, weight.x), weight.y);
}

fn ss_water_ssr(origin: vec3<f32>, direction: vec3<f32>) -> SsWaterReflection {
    var result = SsWaterReflection(vec3<f32>(0.0), 0.0);
    var steps = 12u;
    if quality >= 2u { steps = 18u; }
    if quality >= 3u { steps = 26u; }
    var last_t = 0.12;
    var last_delta = -1.0;
    for (var i = 0u; i < steps; i += 1u) {
        let fraction = (f32(i) + 1.0) / f32(steps);
        let t = 0.15 + fraction * fraction * 64.0;
        let point = origin + direction * t;
        let clip = frame.projection * frame.view * vec4<f32>(point, 1.0);
        if clip.w <= 0.0 { break; }
        let ndc = clip.xyz / clip.w;
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if any(uv <= vec2<f32>(0.002)) || any(uv >= vec2<f32>(0.998)) { break; }
        let depth = textureLoad(opaque_depth, ss_water_pixel(uv), 0);
        if depth > 0.000001 {
            let scene = ss_water_position(uv, depth);
            let delta = length(point) - length(scene);
            if delta > 0.0 && last_delta <= 0.0 && delta < 1.8 + t * 0.025 {
                var near_t = last_t;
                var far_t = t;
                var hit_uv = uv;
                for (var j = 0u; j < 4u; j += 1u) {
                    let middle = (near_t + far_t) * 0.5;
                    let q = origin + direction * middle;
                    let qclip = frame.projection * frame.view * vec4<f32>(q, 1.0);
                    let quv = vec2<f32>(qclip.x / qclip.w * 0.5 + 0.5, 0.5 - qclip.y / qclip.w * 0.5);
                    let qdepth = textureLoad(opaque_depth, ss_water_pixel(quv), 0);
                    let qscene = ss_water_position(quv, max(qdepth, 0.000001));
                    if qdepth > 0.000001 && length(q) > length(qscene) {
                        far_t = middle;
                        hit_uv = quv;
                    } else {
                        near_t = middle;
                    }
                }
                let edge = min(min(hit_uv.x, 1.0 - hit_uv.x), min(hit_uv.y, 1.0 - hit_uv.y));
                result.color = ss_water_color(hit_uv);
                result.confidence = smoothstep(0.0, 0.09, edge) * (1.0 - smoothstep(44.0, 64.0, far_t));
                return result;
            }
            last_delta = delta;
        } else {
            last_delta = -1.0;
        }
        last_t = t;
    }
    return result;
}

fn ss_water_reflection(input: MaterialInput, normal: vec3<f32>) -> vec3<f32> {
    let incident = normalize(input.position);
    let direction = reflect(incident, normal);
    var sky = ss_dimension_sky(direction);
    // Nearby walls block the open sky in a cavern.
    sky *= mix(0.045, 1.0, smoothstep(0.04, 0.70, input.light.y));
    if frame.eye_in == 1u && direction.y < 0.0 {
        sky = vec3<f32>(0.005, 0.035, 0.060) * (0.12 + 0.88 * ss_daylight());
    }
    if !water_reflections || quality == 0u {
        return sky;
    }

    let origin = input.position + normal * 0.035;
    if quality >= 2u && frame.has_ray_tracing == 1u {
        let hit = trace(origin, direction, min(frame.ray_distance, 96.0));
        if hit.distance >= 0.0 {
            let tint = hit.tint.rgb / max(ss_face_shade(hit.normal), 0.12);
            let albedo = hit.albedo.rgb * min(tint, vec3<f32>(1.35));
            let foliage = select(0.0, 1.0, (hit.tags & 1u) != 0u);
            let sources = block_light_color(hit.position);
            let illumination = ss_surface_light(hit.normal, -direction, hit.light,
                ss_shadow(hit.position, hit.normal), sources, vec3<f32>(0.0), foliage);
            let reflected = albedo * illumination + ss_surface_emission(albedo, hit.emission);
            return mix(reflected, sky, 1.0 - exp(-hit.distance * 0.0018));
        }
    }

    let screen_hit = ss_water_ssr(origin, direction);
    return mix(sky, screen_hit.color, screen_hit.confidence);
}

fn ss_water_glitter(normal: vec3<f32>, view: vec3<f32>, light: vec3<f32>, roughness: f32) -> f32 {
    let ndl = max(dot(normal, light), 0.0);
    let ndv = max(dot(normal, view), 0.001);
    let half_sum = view + light;
    let half_vector = half_sum / max(length(half_sum), 0.0001);
    let ndh = max(dot(normal, half_vector), 0.0);
    let vdh = max(dot(view, half_vector), 0.0);
    let a2 = roughness * roughness;
    let denominator = ndh * ndh * (a2 - 1.0) + 1.0;
    let distribution = a2 / max(3.14159265 * denominator * denominator, 0.0000001);
    let masking_v = 2.0 * ndv / (ndv + sqrt(a2 + (1.0 - a2) * ndv * ndv));
    let masking_l = 2.0 * ndl / max(ndl + sqrt(a2 + (1.0 - a2) * ndl * ndl), 0.0001);
    let fresnel = 0.0204 + 0.9796 * pow(1.0 - vdh, 5.0);
    return distribution * masking_v * masking_l * fresnel * ndl / max(4.0 * ndv * ndl, 0.0001);
}

fn sunsun_water(input: MaterialInput) -> Surface {
    let normal = ss_water_wave_normal(input);
    let view = -normalize(input.position);
    let eye_distance = length(input.position);
    let facing = clamp(dot(normal, view), 0.0, 1.0);
    let refractive_index = select(0.75, 1.3333333, frame.eye_in == 1u);
    let transmitted_direction = refract(-view, normal, refractive_index);
    let total_reflection = dot(transmitted_direction, transmitted_direction) < 0.0001;
    let fresnel = select(0.0204 + 0.9796 * pow(1.0 - facing, 5.0), 1.0, total_reflection);

    let surface_depth = textureLoad(opaque_depth, ss_water_pixel(input.screen), 0);
    var behind = ss_water_position(input.screen, max(surface_depth, 0.000001));
    var thickness = clamp(length(behind - input.position), 0.0, 64.0);
    if surface_depth <= 0.000001 { thickness = 48.0; }
    let slope_view = (frame.view * vec4<f32>(normal - input.normal, 0.0)).xy;
    let shift = vec2<f32>(slope_view.x, -slope_view.y) * min(thickness * 0.006, 0.045)
                / (1.0 + eye_distance * 0.035);
    var refracted_uv = clamp(input.screen + shift, vec2<f32>(0.001), vec2<f32>(0.999));
    let moved_depth = textureLoad(opaque_depth, ss_water_pixel(refracted_uv), 0);
    let moved_position = ss_water_position(refracted_uv, max(moved_depth, 0.000001));
    // Reject refraction that pulls a foreground bank across the water.
    if moved_depth <= 0.000001 || length(moved_position) < eye_distance + 0.03 {
        refracted_uv = input.screen;
    } else {
        behind = moved_position;
        thickness = clamp(length(behind - input.position), 0.0, 64.0);
    }

    var bed = ss_water_color(refracted_uv);
    let sky_reach = smoothstep(0.04, 0.80, input.light.y);
    if frame.eye_in != 1u && quality >= 1u && surface_depth > 0.000001 {
        let world_bed = behind + frame.camera_position;
        let path_fade = exp(-thickness * 0.15) * smoothstep(0.05, 0.55, thickness);
        let wave_a = sin(dot(world_bed.xz, vec2<f32>(1.72, 1.13)) + frame.time * 0.77);
        let wave_b = sin(dot(world_bed.xz, vec2<f32>(-1.21, 2.06)) - frame.time * 0.63);
        // A restrained moving bed pattern; no claim of focused-light transport.
        let caustic = pow(max(1.0 - abs(wave_a + wave_b) * 0.75, 0.0), 8.0);
        bed *= 1.0 + caustic * path_fade * sky_reach * ss_daylight() * 0.24;
    }

    let attenuation = exp(-vec3<f32>(0.19, 0.055, 0.024) * thickness);
    let water_light = 0.012 + sky_reach * (0.035 + 0.70 * ss_daylight() + 0.10 * ss_moonlight());
    let scatter = vec3<f32>(0.016, 0.20, 0.27) * water_light;
    var transmission = bed * attenuation + scatter * (vec3<f32>(1.0) - attenuation);
    if frame.eye_in == 1u {
        // Above the surface is air; the post stage applies the camera's water path.
        transmission = bed;
    }

    let reflected = ss_water_reflection(input, normal);
    let roughness = 0.035 + frame.rain * 0.018 + min(eye_distance * 0.00012, 0.025);
    let shadow = ss_shadow(input.position, input.normal);
    let solar = ss_water_glitter(normal, view, frame.sun_direction, roughness)
                * ss_sun_color() * ss_daylight() * (1.0 - frame.rain * 0.82) * 0.38;
    let lunar = ss_water_glitter(normal, view, frame.moon_direction, roughness + 0.012)
                * vec3<f32>(0.19, 0.26, 0.40) * ss_moonlight() * 0.12;
    let color = mix(transmission, reflected, fresnel) + min(solar + lunar, vec3<f32>(4.0)) * shadow * sky_reach;
    return Surface(vec4<f32>(max(color, vec3<f32>(0.0)), 1.0));
}
