// SPDX-License-Identifier: Apache-2.0
// Focus and motion blur have separate passes so enabling both preserves each.
fn ss_focus_distance(uv: vec2<f32>) -> f32 {
    return min(length(view_position(uv, max(depth_at(uv), 0.000001))), frame.far);
}

fn post(input: PostInput) -> vec4<f32> {
    var color = input.color.rgb;
    if depth_of_field {
        let focus = max(ss_focus_distance(vec2<f32>(0.5)), 1.0);
        let distance = max(ss_focus_distance(input.uv), 0.5);
        let radius = min(abs(1.0 / focus - 1.0 / distance) * 100.0, 5.0);
        if radius > 0.2 {
            var sum = color;
            var weight = 1.0;
            let texel = 1.0 / frame.resolution;
            for (var i = 0u; i < 8u; i += 1u) {
                let angle = f32(i) * 2.39996323;
                let ring = sqrt((f32(i) + 0.5) / 8.0);
                let uv = clamp(input.uv + vec2<f32>(cos(angle), sin(angle)) * ring * radius * texel,
                    vec2<f32>(0.001), vec2<f32>(0.999));
                let sample_distance = ss_focus_distance(uv);
                let accepted = smoothstep(0.0, 1.0, sample_distance / distance);
                sum += textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb * accepted;
                weight += accepted;
            }
            color = sum / weight;
        }
    }
    return vec4<f32>(color, 1.0);
}
