// SPDX-License-Identifier: Apache-2.0
fn post(input: PostInput) -> vec4<f32> {
    if bloom <= 0.0 { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    let texel = 1.0 / vec2<f32>(textureDimensions(ss_bright));
    var color = vec3<f32>(0.0);
    var total = 0.0;
    let extent = select(4i, 2i, quality == 0u);
    for (var i = -extent; i <= extent; i += 1i) {
        let x = f32(i);
        let weight = exp(-x * x / 7.0);
        color += textureSampleLevel(ss_bright, linear_sampler,
            input.uv + vec2<f32>(x * texel.x * 2.2, 0.0), 0.0).rgb * weight;
        total += weight;
    }
    return vec4<f32>(color / total, 1.0);
}
