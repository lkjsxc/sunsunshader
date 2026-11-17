// Copyright 2026 Sunsun Shader contributors. SPDX-License-Identifier: Apache-2.0
// Water is shaded at its actual surface; the post depth has no water mask.
// Fresnel and GGX follow Walter et al., "Microfacet Models for Refraction
// through Rough Surfaces", EGSR 2007. The waves, filtering and screen search
// are original. No native mirror is used: its sky has no exposed coverage mask.

struct SsWaterReflection {
    color: vec3<f32>,
    confidence: f32,
}

fn ss_water_hash(p: vec2<f32>) -> f32 {
    let folded = fract(p * vec2<f32>(0.1037, 0.1193));
    let mixed = folded + dot(folded, folded.yx + vec2<f32>(19.17, 37.41));
    return fract((mixed.x + mixed.y) * (mixed.x + 0.41));
}

// Integer cycles keep motion continuous across Frame.time's hourly wrap.
fn ss_water_phase(cycles: f32) -> f32 {
    return SS_TAU * fract((frame.time / 3600.0) * cycles);
}

fn ss_water_footprint(input: MaterialInput) -> f32 {
    let distance = max(length(input.position), 0.001);
    let facing = max(abs(dot(-input.position / distance, input.normal)), 0.025);
    return 2.0 * distance
        / max(frame.resolution.y * abs(frame.projection[1].y) * facing, 1.0);
}

fn ss_water_wave_normal(input: MaterialInput) -> vec3<f32> {
    if input.face != 1u || water_waves <= 0.0 {
        return input.normal;
    }
    let p = (input.position + frame.camera_position).xz;
    let warp_x = vec2<f32>(0.071, 0.049);
    let warp_z = vec2<f32>(-0.037, 0.083);
    let warp_phase = vec2<f32>(dot(p, warp_x) + ss_water_phase(17.0),
                              dot(p, warp_z) - ss_water_phase(23.0));
    let warped = p + sin(warp_phase) * 2.4;
    let warp_gradient = cos(warp_phase) * 2.4;
    let footprint = ss_water_footprint(input);
    // Three scales, two crossing directions each. The long swell survives at
    // a grazing angle; fine ripples disappear before they can crawl in pixels.
    let a = vec2<f32>(0.27, 0.13);
    let b = vec2<f32>(-0.18, 0.43);
    let c = vec2<f32>(0.83, 0.37);
    let d = vec2<f32>(-0.51, 1.19);
    let e = vec2<f32>(1.89, -0.93);
    let f = vec2<f32>(-2.31, -1.47);
    let broad_filter = vec2<f32>(1.0) - smoothstep(vec2<f32>(0.65),
        vec2<f32>(2.2), footprint * vec2<f32>(0.300, 0.466));
    let middle_filter = vec2<f32>(1.0) - smoothstep(vec2<f32>(0.65),
        vec2<f32>(2.2), footprint * vec2<f32>(0.909, 1.295));
    let fine_filter = vec2<f32>(1.0) - smoothstep(vec2<f32>(0.65),
        vec2<f32>(2.2), footprint * vec2<f32>(2.107, 2.738));
    let derivative =
          a * cos(dot(warped, a) + ss_water_phase(173.0)) * 0.220 * broad_filter.x
        + b * cos(dot(warped, b) - ss_water_phase(247.0)) * 0.140 * broad_filter.y
        + c * cos(dot(warped, c) + ss_water_phase(421.0)) * 0.100 * middle_filter.x
        + d * cos(dot(warped, d) - ss_water_phase(563.0)) * 0.068 * middle_filter.y
        + e * cos(dot(warped, e) + ss_water_phase(817.0)) * 0.014 * fine_filter.x
        + f * cos(dot(warped, f) - ss_water_phase(1009.0)) * 0.010 * fine_filter.y;
    // The Jacobian keeps these normals a derivative of one moving height field.
    var slope = vec2<f32>(
        derivative.x * (1.0 + warp_gradient.x * warp_x.x)
            + derivative.y * warp_gradient.y * warp_z.x,
        derivative.x * warp_gradient.x * warp_x.y
            + derivative.y * (1.0 + warp_gradient.y * warp_z.y));
    if frame.rain > 0.01 && frame.precipitation == 1u {
        let grid = p * 0.8;
        let cell = floor(grid);
        let h = ss_water_hash(cell);
        let centre = vec2<f32>(0.5)
            + (vec2<f32>(h, ss_water_hash(cell + 71.0)) - 0.5) * 0.20;
        let delta = fract(grid) - centre;
        let r = length(delta);
        let age = fract(fract((frame.time / 3600.0) * 2844.0) + h);
        let ring = r - age * 0.40;
        let envelope = exp(-ring * ring * 240.0) * (1.0 - age)
            * (1.0 - smoothstep(0.30, 0.48, r));
        let ripple_filter = 1.0 - smoothstep(0.65, 2.2, footprint * 46.4);
        slope += delta / max(r, 0.025) * cos(ring * 58.0)
            * envelope * frame.rain * 0.045 * ripple_filter;
    }
    let distance_fade = 1.0 / (1.0 + length(input.position) * 0.0015);
    let upward = normalize(vec3<f32>(-slope.x * water_waves * distance_fade,
        1.0, -slope.y * water_waves * distance_fade));
    return upward * select(-1.0, 1.0, input.normal.y >= 0.0);
}

// The reflected cloud image follows the resolved swell. Finer capillary slopes
// only break the direct sun response into small highlights; their energy folds
// into roughness once a pixel can no longer resolve them.
fn ss_water_specular_normal(input: MaterialInput, normal: vec3<f32>) -> vec3<f32> {
    if input.face != 1u || water_waves <= 0.0 {
        return normal;
    }
    let p = (input.position + frame.camera_position).xz;
    let a = vec2<f32>(5.61, 2.27);
    let b = vec2<f32>(-3.49, 7.83);
    let footprint = ss_water_footprint(input);
    let filtered = vec2<f32>(1.0) - smoothstep(vec2<f32>(0.45),
        vec2<f32>(1.50), footprint * vec2<f32>(6.052, 8.572));
    let slope = a * cos(dot(p, a) + ss_water_phase(1319.0)) * 0.0041 * filtered.x
        + b * cos(dot(p, b) - ss_water_phase(1777.0)) * 0.0026 * filtered.y;
    let strength = water_waves / (1.0 + length(input.position) * 0.0015);
    let side = select(-1.0, 1.0, normal.y >= 0.0);
    return normalize(normal + vec3<f32>(-slope.x, 0.0, -slope.y) * strength * side);
}

fn ss_water_pixel(uv: vec2<f32>) -> vec2<i32> {
    let size = vec2<i32>(textureDimensions(opaque_depth));
    return clamp(vec2<i32>(uv * vec2<f32>(size)), vec2<i32>(0), size - vec2<i32>(1));
}

fn ss_water_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view = frame.projection_inverse * clip;
    return (frame.view_inverse
        * vec4<f32>(view.xyz / max(abs(view.w), 0.000001), 0.0)).xyz;
}

fn ss_water_eye_depth(uv: vec2<f32>, depth: f32) -> f32 {
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view = frame.projection_inverse * clip;
    return abs(view.z) / max(abs(view.w), 0.000001);
}

// The ordinary Nightly exposes unfilterable opaque colour; interpolate four
// decoded texels so reflected and refracted banks do not jump between pixels.
fn ss_water_color(uv: vec2<f32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(opaque_color));
    let pixel = clamp(uv * vec2<f32>(size) - 0.5,
        vec2<f32>(0.0), vec2<f32>(size - vec2<i32>(1)));
    let base = vec2<i32>(floor(pixel));
    let top = min(base + vec2<i32>(1), size - vec2<i32>(1));
    let weight = fract(pixel);
    let a = ss_decode(textureLoad(opaque_color, base, 0).rgb);
    let b = ss_decode(textureLoad(opaque_color, vec2<i32>(top.x, base.y), 0).rgb);
    let c = ss_decode(textureLoad(opaque_color, vec2<i32>(base.x, top.y), 0).rgb);
    let d = ss_decode(textureLoad(opaque_color, top, 0).rgb);
    return mix(mix(a, b, weight.x), mix(c, d, weight.x), weight.y);
}

fn ss_water_ssr(origin: vec3<f32>, direction: vec3<f32>,
    surface_y: f32) -> SsWaterReflection {
    var result = SsWaterReflection(vec3<f32>(0.0), 0.0);
    let steps = select(12u, 24u, quality >= 2u);
    let reach = select(64.0, 96.0, quality >= 2u);
    var last_t = 0.12;
    var last_delta = -1.0;
    for (var i = 0u; i < steps; i += 1u) {
        let fraction = (f32(i) + 1.0) / f32(steps);
        let t = 0.15 + fraction * fraction * reach;
        let point = origin + direction * t;
        let eye = frame.view * vec4<f32>(point, 1.0);
        let clip = frame.projection * eye;
        if clip.w <= 0.001 { break; }
        let uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5,
            0.5 - clip.y / clip.w * 0.5);
        if any(uv <= vec2<f32>(0.002)) || any(uv >= vec2<f32>(0.998)) { break; }
        let depth = textureLoad(opaque_depth, ss_water_pixel(uv), 0);
        if depth > 0.000001 {
            let delta = abs(eye.z) - ss_water_eye_depth(uv, depth);
            if delta > 0.0 && last_delta <= 0.0 {
                var near_t = last_t;
                var far_t = t;
                var hit_uv = uv;
                var hit_gap = delta;
                var hit_depth = depth;
                for (var j = 0u; j < 4u; j += 1u) {
                    let middle = (near_t + far_t) * 0.5;
                    let q = frame.view * vec4<f32>(origin + direction * middle, 1.0);
                    let qclip = frame.projection * q;
                    let quv = vec2<f32>(qclip.x / qclip.w * 0.5 + 0.5,
                        0.5 - qclip.y / qclip.w * 0.5);
                    let qdepth = textureLoad(opaque_depth, ss_water_pixel(quv), 0);
                    let gap = abs(q.z) - ss_water_eye_depth(quv, max(qdepth, 0.000001));
                    if qdepth > 0.000001 && gap > 0.0 {
                        far_t = middle;
                        hit_uv = quv;
                        hit_gap = gap;
                        hit_depth = qdepth;
                    } else {
                        near_t = middle;
                    }
                }
                // A depth discontinuity is not a solid wall extending behind
                // its silhouette. Reject a crossing whose refined ray is too
                // far behind the visible surface.
                let thickness_limit = 0.18 + far_t * 0.012;
                let agreement = 1.0 - smoothstep(thickness_limit * 0.30,
                    thickness_limit, hit_gap);
                let edge = min(min(hit_uv.x, 1.0 - hit_uv.x),
                    min(hit_uv.y, 1.0 - hit_uv.y));
                // Opaque depth includes the submerged bed, but contains no
                // water. A downward wave ray must not mistake that bed for
                // above-water reflected shore. The transition is in blocks.
                let hit_position = ss_water_position(hit_uv, hit_depth);
                let above_water = smoothstep(-0.04, 0.18, hit_position.y - surface_y);
                let fade = smoothstep(0.015, 0.11, edge)
                    * (1.0 - smoothstep(reach * 0.68, reach, far_t)) * above_water;
                if agreement * fade > 0.001 {
                    result.color = ss_water_color(hit_uv);
                    result.confidence = agreement * fade;
                    return result;
                }
                // The first ambiguous crossing falls back to the sky. Searching
                // through it would invent hidden shore and multiply the work.
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
    let direction = reflect(normalize(input.position), normal);
    let open_sky = mix(0.025, 1.0, smoothstep(0.025, 0.60, input.light.y));
    var sky = ss_dimension_sky(direction);
    var screen_hit = SsWaterReflection(vec3<f32>(0.0), 0.0);
    if water_reflections && quality > 0u {
        screen_hit = ss_water_ssr(input.position + normal * 0.055, direction, input.position.y);
        if screen_hit.confidence >= 0.999 {
            return screen_hit.color;
        }
    }
    // Reflections use the same world-space clouds at Medium too. Their
    // filtered path has a smaller transport budget, not a different sky.
    if quality >= 1u && frame.eye_in != 1u {
        let pixel_angle = 2.0 / max(frame.resolution.y * abs(frame.projection[1].y), 1.0);
        let angular_cone = clamp(pixel_angle + ss_water_footprint(input) * 0.10,
            pixel_angle, 0.06);
        sky = ss_cloud_reflection(sky, direction,
            input.position + frame.camera_position, angular_cone);
    }
    sky *= open_sky;
    if frame.eye_in == 1u && direction.y < 0.0 {
        sky = vec3<f32>(0.004, 0.022, 0.052)
            * (0.12 + 0.88 * ss_daylight());
    }
    return mix(sky, screen_hit.color, screen_hit.confidence);
}

fn ss_water_glitter(normal: vec3<f32>, view: vec3<f32>,
    light: vec3<f32>, roughness: f32) -> f32 {
    let ndl = max(dot(normal, light), 0.0);
    let ndv = max(dot(normal, view), 0.001);
    let half_sum = view + light;
    let half_vector = half_sum / max(length(half_sum), 0.0001);
    let ndh = max(dot(normal, half_vector), 0.0);
    let vdh = max(dot(view, half_vector), 0.0);
    let a2 = roughness * roughness;
    let denominator = ndh * ndh * (a2 - 1.0) + 1.0;
    let distribution = a2 / max(SS_PI * denominator * denominator, 0.0000001);
    let masking_v = 2.0 * ndv / (ndv + sqrt(a2 + (1.0 - a2) * ndv * ndv));
    let masking_l = 2.0 * ndl
        / max(ndl + sqrt(a2 + (1.0 - a2) * ndl * ndl), 0.0001);
    let fresnel = 0.0204 + 0.9796 * pow(1.0 - vdh, 5.0);
    return distribution * masking_v * masking_l * fresnel * ndl
        / max(4.0 * ndv * ndl, 0.0001);
}

fn sunsun_water(input: MaterialInput) -> Surface {
    let normal = ss_water_wave_normal(input);
    let view = -normalize(input.position);
    let eye_distance = length(input.position);
    let facing = clamp(dot(normal, view), 0.0, 1.0);
    let refractive_index = select(0.75, 1.3333333, frame.eye_in == 1u);
    let transmitted_direction = refract(-view, normal, refractive_index);
    let total_reflection = dot(transmitted_direction, transmitted_direction) < 0.0001;
    let fresnel = select(0.0204 + 0.9796 * pow(1.0 - facing, 5.0),
        1.0, total_reflection);

    let surface_depth = textureLoad(opaque_depth, ss_water_pixel(input.screen), 0);
    var behind = ss_water_position(input.screen, max(surface_depth, 0.000001));
    var thickness = clamp(length(behind - input.position), 0.0, 64.0);
    if surface_depth <= 0.000001 { thickness = 48.0; }
    // A vanishing water column transmits its actual bank without a hard
    // reflected line. This uses scene depth, not a painted shoreline.
    let shore = smoothstep(0.015, 0.32, thickness);
    let slope_view = (frame.view * vec4<f32>(normal - input.normal, 0.0)).xy;
    let shift = vec2<f32>(slope_view.x, -slope_view.y)
        * min(thickness * 0.012, 0.060) * shore
        / (1.0 + eye_distance * 0.018);
    var refracted_uv = clamp(input.screen + shift,
        vec2<f32>(0.001), vec2<f32>(0.999));
    let moved_depth = textureLoad(opaque_depth, ss_water_pixel(refracted_uv), 0);
    let moved_position = ss_water_position(refracted_uv, max(moved_depth, 0.000001));
    let water_eye = abs((frame.view * vec4<f32>(input.position, 1.0)).z);
    if moved_depth <= 0.000001
        || ss_water_eye_depth(refracted_uv, moved_depth) <= water_eye + 0.035 {
        refracted_uv = input.screen;
    } else {
        behind = moved_position;
        thickness = clamp(length(behind - input.position), 0.0, 64.0);
    }

    var bed = ss_water_color(refracted_uv);
    let sky_reach = smoothstep(0.025, 0.80, input.light.y);
    if frame.eye_in != 1u && quality >= 1u && surface_depth > 0.000001 {
        let world_bed = behind + frame.camera_position;
        let path_fade = exp(-thickness * 0.22)
            * smoothstep(0.04, 0.45, thickness);
        let wave_a = sin(dot(world_bed.xz, vec2<f32>(1.72, 1.13))
            + ss_water_phase(441.0));
        let wave_b = sin(dot(world_bed.xz, vec2<f32>(-1.21, 2.06))
            - ss_water_phase(361.0));
        // A small moving bed modulation, not a claim of focused-light transport.
        let caustic = pow(max(1.0 - abs(wave_a + wave_b) * 0.75, 0.0), 8.0);
        bed *= 1.0 + caustic * path_fade * sky_reach * ss_daylight() * 0.32;
    }

    let attenuation = exp(-vec3<f32>(0.205, 0.064, 0.030) * thickness);
    let water_light = 0.010 + sky_reach
        * (0.025 + 0.82 * ss_daylight() + 0.10 * ss_moonlight());
    let scatter = vec3<f32>(0.006, 0.066, 0.145) * water_light;
    var transmission = bed * attenuation
        + scatter * (vec3<f32>(1.0) - attenuation);
    if frame.eye_in == 1u {
        // Above the surface is air; the post supplies the camera's water path.
        transmission = bed;
    }

    let reflected = ss_water_reflection(input, normal);
    // Preserve the energy of filtered-out ripples in a wider stable lobe.
    let footprint = ss_water_footprint(input);
    let unresolved = smoothstep(0.08, 1.8, footprint);
    let roughness = 0.060 + frame.rain * 0.028 + unresolved * 0.045;
    let shadow = ss_shadow(input.position, input.normal);
    let direct_open = select(sky_reach, 1.0, shadows && frame.has_shadow != 0u);
    let specular_normal = ss_water_specular_normal(input, normal);
    let sun_glint = ss_water_glitter(specular_normal, view, frame.sun_direction, roughness);
    let sun_skirt = ss_water_glitter(normal, view, frame.sun_direction,
        roughness * 1.8 + 0.035);
    let solar = (sun_glint * 0.82 + sun_skirt * 0.34)
        * ss_sun_color() * ss_daylight() * (1.0 - frame.rain * 0.85);
    let lunar = ss_water_glitter(specular_normal, view, frame.moon_direction, roughness + 0.025)
        * vec3<f32>(0.24, 0.37, 0.62) * ss_moonlight() * 0.36;
    let reflection_amount = select(fresnel * shore, fresnel, frame.eye_in == 1u);
    let base = mix(transmission, reflected, reflection_amount);
    let direct = (solar + lunar) * shadow * direct_open * shore;
    // Ordinary Nightly stores the world in a bounded colour target. Compress
    // direct sparkle continuously into its remaining headroom before encoding,
    // so a large GGX peak keeps gradation instead of becoming a solid oval.
    let headroom = max(1.0 - max(base.x, max(base.y, base.z)), 0.0);
    let direct_peak = max(direct.x, max(direct.y, direct.z));
    let color = base + direct * (headroom / max(headroom + direct_peak, 0.000001));
    return Surface(vec4<f32>(ss_encode(max(color, vec3<f32>(0.0))), 1.0));
}
