// SPDX-License-Identifier: Apache-2.0

fn entity(input: EntityInput) -> Surface {
    let normal = input.normal;
    let view = -normalize(input.position + vec3<f32>(0.0, 0.000001, 0.0));
    let albedo = input.albedo.rgb * input.tint.rgb;
    let sources = block_light_color(input.position);
    let illumination = ss_surface_light(normal, view, input.light, ss_shadow(input.position, normal),
        sources, input.colored_light, 0.0);
    let flashed = mix(albedo, input.overlay.rgb, input.overlay.a);
    let color = flashed * illumination + ss_surface_emission(albedo, input.emission);
    return Surface(vec4<f32>(color, input.albedo.a * input.tint.a));
}
