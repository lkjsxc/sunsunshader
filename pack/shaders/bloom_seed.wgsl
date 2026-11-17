// SPDX-License-Identifier: Apache-2.0
// Soft threshold and a compact downsample keep small emitters from flashing.
fn post(input: PostInput) -> vec4<f32> {
    if bloom <= 0.0 { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    let texel = 1.0 / frame.resolution;
    var sum = vec3<f32>(0.0);
    var total = 0.0;
    for (var y = -1i; y <= 1i; y += 1i) {
        for (var x = -1i; x <= 1i; x += 1i) {
            let weight = select(1.0, 2.0, x == 0i) * select(1.0, 2.0, y == 0i);
            let color = textureSampleLevel(previous, linear_sampler,
                input.uv + vec2<f32>(f32(x), f32(y)) * texel * 1.5, 0.0).rgb;
            let luma = dot(color, frame.luminance);
            let knee = smoothstep(0.55, 1.3, luma);
            sum += color * knee * weight;
            total += weight;
        }
    }
    return vec4<f32>(sum / total, 1.0);
}
