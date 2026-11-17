// SPDX-License-Identifier: Apache-2.0

fn material(source: MaterialInput) -> Surface {
    var input = source;
    input.albedo = vec4<f32>(ss_decode(source.albedo.rgb), source.albedo.a);
    input.tint = vec4<f32>(ss_decode(source.tint.rgb), source.tint.a);
    input.colored_light = ss_decode(source.colored_light);
    if input.fluid == 1u {
        return sunsun_water(input);
    }
    let normal = input.normal;
    let view = -normalize(input.position + vec3<f32>(0.0, 0.000001, 0.0));
    // Remove only the known face shade; biome colour and baked occlusion remain.
    let tint = input.tint.rgb / max(ss_face_shade(normal), 0.12);
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
    let sources = ss_decode_light(block_light_color(input.position));
    let visibility = ss_shadow(input.position, normal);
    let illumination = ss_surface_light(normal, view, input.light, visibility,
        sources, input.colored_light, foliage);
    var color = albedo * illumination;
    color += ss_surface_emission(albedo, input.emission);
    if wet > 0.001 && !input.translucent {
        let facing = max(dot(normal, view), 0.0);
        let fresnel = 0.025 + 0.975 * pow(1.0 - facing, 5.0);
        let reflection = ss_dimension_sky(reflect(-view, normal));
        color = mix(color, reflection, min(fresnel * wet * 0.35, 0.25));
        let sparkle = ss_water_glitter(normal, view, frame.sun_direction, 0.18);
        color += min(sparkle, 0.8) * ss_sun_color() * ss_daylight()
            * visibility * wet * 0.24;
    }
    if (input.tags & 2u) != 0u {
        let mineral = max(max(albedo.r, albedo.g), albedo.b) - min(min(albedo.r, albedo.g), albedo.b);
        color += albedo * smoothstep(0.12, 0.42, mineral) * 0.12;
    }
    if !input.translucent {
        set_surface(normal, wet * 0.65, input.emission);
    }
    // Before the coverage-default change, the Nightly tests returned alpha.
    // Vertex tint alpha must not punch holes through an opaque cutout.
    let coverage = select(input.albedo.a, input.albedo.a * input.tint.a, input.translucent);
    return Surface(vec4<f32>(ss_encode(color), coverage));
}
