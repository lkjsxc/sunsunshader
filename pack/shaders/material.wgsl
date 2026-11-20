// SPDX-License-Identifier: Apache-2.0

fn ss_haze_inward_cage_face(position: vec3<f32>, normal: vec3<f32>) -> bool {
    if !any(abs(normal) == vec3<f32>(1.0)) { return false; }
    // The trial cage's inner shell sits 0.002 / 16 blocks inward from
    // each integer plane and faces into the cage. The outer shell is flush.
    let relative = position + fract(frame.camera_position);
    let inset = dot(relative - round(relative), normal);
    return abs(inset - 0.002 / 16.0) < 1.0 / 16384.0;
}

fn material(input: MaterialInput) -> Surface {
    if input.fluid == 1u {
        return sunsun_water(input);
    }
    // 9f42064 hdr_tier explicitly excluded glow lichen. Restore that input
    // semantic for this exact sprite; its native receiver light stays intact.
    // The third manifest sprite tag has mask 4u (index 2); earlier tags stay fixed.
    let emission = select(input.emission, 0.0, (input.tags & 4u) != 0u);
    // The sprite ID is independent of per-block light. Classify the original
    // sampled texel, before face tint, wet darkening and weather desaturation.
    // Fade the distinction at mip distance rather than classifying mixed mips.
    var colour_emission = emission;
    if (input.tags & 16u) != 0u {
        let texel = input.albedo.rgb;
        let brightness = 0.5 * (dot(texel, vec3<f32>(0.2126, 0.7152, 0.0722))
            + max(texel.r, max(texel.g, texel.b)));
        let glass = smoothstep(0.12, 0.35, brightness);
        let near = 1.0 - smoothstep(12.0, 24.0, length(input.position));
        colour_emission = emission * mix(1.0, glass, near);
    }
    let normal = input.normal;
    let view = -normalize(input.position + vec3<f32>(0.0, 0.000001, 0.0));
    // Read the combined native vertex tint retained by API 0.2, already linear.
    // Remove only the known face shade; biome colour and baked occlusion remain.
    let tint = input.shaded_tint.rgb / max(ss_face_shade(normal), 0.12);
    var albedo = input.albedo.rgb * min(tint, vec3<f32>(1.35));
    let foliage = select(0.0, 1.0, (input.tags & 1u) != 0u);
    var wet = 0.0;
    if weather_detail && frame.dimension == 0 && input.fluid == 0u {
        let exposed = pow(clamp(input.light.y, 0.0, 1.0), 3.0);
        let moisture = max(frame.wetness, frame.rain * 0.55);
        wet = moisture * exposed * (1.0 - foliage * 0.70);
        albedo *= 1.0 - wet * 0.20;
        let luma = dot(albedo, vec3<f32>(0.2126, 0.7152, 0.0722));
        albedo = mix(albedo, vec3<f32>(luma), frame.rain * 0.10);
        // Only the camera biome is exposed by this API; coverage stays subtle.
        let cold = 1.0 - smoothstep(0.03, 0.17, frame.temperature);
        let upward = smoothstep(0.45, 0.95, normal.y);
        let fleck = ss_noise3((input.position + frame.camera_position) * 1.2);
        let coat = cold * upward * exposed * (0.06 + moisture * 0.30) * smoothstep(0.22, 0.70, fleck);
        albedo = mix(albedo, vec3<f32>(0.72, 0.80, 0.84), coat);
    }
    let sources = block_light_color(input.position);
    let visibility = ss_shadow(input.position, normal);
    let illumination = ss_surface_light(normal, view, input.light, visibility,
        sources, input.colored_light, foliage, colour_emission);
    var color = albedo * illumination;
    color += ss_surface_emission(albedo, colour_emission);
    if wet > 0.001 && !input.translucent {
        let facing = max(dot(normal, view), 0.0);
        let fresnel = 0.025 + 0.975 * pow(1.0 - facing, 5.0);
        let reflection = ss_dimension_sky(reflect(-view, normal))
            * smoothstep(0.02, 0.55, input.light.y);
        color = mix(color, reflection, min(fresnel * wet * 0.35, 0.25));
        let sparkle = ss_water_glitter(normal, view, frame.sun_direction, 0.18);
        color += min(sparkle, 0.8) * ss_sun_color() * ss_daylight()
            * visibility * wet * 0.24;
    }
    if colour_emission > 0.001 {
        // Retain rc3's source texture shoulder before the compatibility range bound.
        // A continuous shoulder avoids the flat hue-normalized lava plateau.
        let peak = max(color.r, max(color.g, color.b));
        let source_peak = 1.0 - exp(-max(peak, 0.0) * 1.10);
        color *= mix(1.0, source_peak / max(peak, 0.00001), clamp(colour_emission, 0.0, 1.0));
    }
    if !input.translucent {
        // Reserved native-B codec; the actual wet lighting above stays unchanged.
        let inward = (input.tags & 8u) != 0u && ss_haze_inward_cage_face(input.position, normal);
        set_surface(normal, ss_haze_encode_receiver(input.light.x, inward), ss_surface_data(input.light, emission, sources));
    }
    // Engine coverage keeps the native cutout test; translucent alpha stays coverage.
    // Keep rc3's texture/tint coverage expression without changing geometry.
    let coverage = select(input.albedo.a, input.albedo.a * input.shaded_tint.a, input.translucent);
    return Surface(vec4<f32>(ss_world_bound(color), coverage));
}
