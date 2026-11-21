// SPDX-License-Identifier: Apache-2.0
fn ss_picture_at(uv: vec2<f32>) -> vec3<f32> {
    let point = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
    let scene = textureSampleLevel(previous, linear_sampler, point, 0.0).rgb;
    let glow = textureSampleLevel(ss_bloom, linear_sampler, point, 0.0).rgb;
    return scene + glow * bloom;
}

fn ss_moving_picture_at(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    var color = ss_picture_at(uv);
    if camera_motion_blur && frame.delta_time > 0.0 && frame.delta_time < 0.15 {
        let position = view_position(uv, max(depth, 0.000001));
        let previous = position + frame.camera_motion;
        let previous_clip = frame.previous_view_projection * vec4<f32>(previous, 1.0);
        let previous_distance = max(length(previous), 0.000001);
        let fade = smoothstep(0.0, 0.1, previous_clip.w / previous_distance);
        if fade > 0.0 {
            // Floor the divisor inside the fade band before the pixel-space length.
            let projection_w = max(previous_clip.w, 0.002 * previous_distance);
            let old_uv = vec2<f32>(previous_clip.x / projection_w * 0.5 + 0.5,
                0.5 - previous_clip.y / projection_w * 0.5);
            var motion = (uv - old_uv) * 0.30;
            let pixels = length(motion * frame.resolution);
            motion *= min(1.0, 12.0 / max(pixels, 0.01));
            var blurred = color;
            for (var i = 1u; i <= 4u; i += 1u) {
                blurred += ss_picture_at(uv - motion * (f32(i) / 4.0));
            }
            blurred /= 5.0;
            if fade >= 1.0 {
                color = blurred;
            } else {
                color = mix(color, blurred, fade);
            }
        }
    }
    return color;
}

fn post(input: PostInput) -> vec4<f32> {
    return vec4<f32>(ss_focus(input.uv, ss_moving_picture_at(input.uv, input.depth)), 1.0);
}
