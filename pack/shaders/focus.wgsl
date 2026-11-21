// SPDX-License-Identifier: Apache-2.0
// Focus samples the same moving-picture function as Compose.
fn ss_focus_distance(uv: vec2<f32>) -> f32 {
    return min(length(view_position(uv, max(depth_at(uv), 0.000001))), frame.far);
}

fn ss_focus(uv: vec2<f32>, center: vec3<f32>) -> vec3<f32> {
    var color = center;
    if depth_of_field {
        let focus = max(ss_focus_distance(vec2<f32>(0.5)), 1.0);
        let distance = max(ss_focus_distance(uv), 0.5);
        let radius = min(abs(1.0 / focus - 1.0 / distance) * 100.0, 5.0);
        let blur = smoothstep(0.15, 0.25, radius);
        if blur > 0.0 {
            var sum = color;
            var weight = 1.0;
            let texel = 1.0 / frame.resolution;
            for (var i = 0u; i < 8u; i += 1u) {
                let angle = f32(i) * 2.39996323;
                let ring = sqrt((f32(i) + 0.5) / 8.0);
                let uv = clamp(uv + vec2<f32>(cos(angle), sin(angle)) * ring * radius * texel,
                    vec2<f32>(0.001), vec2<f32>(0.999));
                let sample_distance = ss_focus_distance(uv);
                let accepted = smoothstep(0.0, 1.0, sample_distance / distance);
                sum += ss_moving_picture_at(uv, depth_at(uv)) * accepted;
                weight += accepted;
            }
            let filtered = sum / weight;
            if blur >= 1.0 {
                color = filtered;
            } else {
                color = mix(color, filtered, blur);
            }
        }
    }
    return color;
}
