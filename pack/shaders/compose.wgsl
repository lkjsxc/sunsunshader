// SPDX-License-Identifier: Apache-2.0
fn ss_picture_at(uv: vec2<f32>) -> vec3<f32> {
    let point = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
    let scene = textureSampleLevel(previous, linear_sampler, point, 0.0).rgb;
    let glow = textureSampleLevel(ss_bloom, linear_sampler, point, 0.0).rgb;
    return scene + glow * bloom;
}

fn post(input: PostInput) -> vec4<f32> {
    var color = ss_picture_at(input.uv);
    if camera_motion_blur && frame.delta_time > 0.0 && frame.delta_time < 0.15 {
        let position = view_position(input.uv, max(input.depth, 0.000001));
        let previous_clip = frame.previous_view_projection * vec4<f32>(position + frame.camera_motion, 1.0);
        if previous_clip.w > 0.0 {
            let old_uv = vec2<f32>(previous_clip.x / previous_clip.w * 0.5 + 0.5,
                0.5 - previous_clip.y / previous_clip.w * 0.5);
            var motion = (input.uv - old_uv) * 0.30;
            let pixels = length(motion * frame.resolution);
            motion *= min(1.0, 12.0 / max(pixels, 0.01));
            for (var i = 1u; i <= 4u; i += 1u) {
                color += ss_picture_at(input.uv - motion * (f32(i) / 4.0));
            }
            color /= 5.0;
        }
    }
    return vec4<f32>(color, 1.0);
}
