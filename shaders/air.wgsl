// SPDX-License-Identifier: Apache-2.0

fn ss_screen_direction(uv: vec2<f32>) -> vec3<f32> {
    let point = frame.projection_inverse * vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.00001, 1.0);
    return normalize((frame.view_inverse * vec4<f32>(point.xyz, 0.0)).xyz);
}

fn post(input: PostInput) -> vec4<f32> {
    if input.depth <= 0.0000001 {
        if frame.dimension == -1 || frame.dimension == 1 {
            return vec4<f32>(ss_dimension_sky(ss_screen_direction(input.uv)), 1.0);
        }
        return vec4<f32>(input.color.rgb, 1.0);
    }
    let position = view_position(input.uv, input.depth);
    return vec4<f32>(ss_fog(input.color.rgb, position), 1.0);
}
