// SPDX-License-Identifier: Apache-2.0

fn material(input: MaterialInput) -> Surface {
    let normal = input.normal;
    let view = -normalize(input.position + vec3<f32>(0.0, 0.000001, 0.0));
    // Remove only the known face shade; biome colour and baked occlusion remain.
    let tint = input.tint.rgb / max(ss_face_shade(normal), 0.12);
    let albedo = input.albedo.rgb * min(tint, vec3<f32>(1.35));
    let foliage = select(0.0, 1.0, (input.tags & 1u) != 0u);
    let sources = block_light_color(input.position);
    let illumination = ss_surface_light(normal, view, input.light, vec3<f32>(1.0),
        sources, input.colored_light, foliage);
    var color = albedo * illumination;
    color += ss_surface_emission(albedo, input.emission);
    if (input.tags & 2u) != 0u {
        let mineral = max(max(albedo.r, albedo.g), albedo.b) - min(min(albedo.r, albedo.g), albedo.b);
        color += albedo * smoothstep(0.12, 0.42, mineral) * 0.12;
    }
    if !input.translucent {
        set_surface(normal, 0.0, 0.0);
    }
    return Surface(vec4<f32>(color, input.albedo.a * input.tint.a));
}
