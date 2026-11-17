// SPDX-License-Identifier: Apache-2.0
fn weather(input: WeatherInput) -> vec4<f32> {
    let day = ss_daylight();
    let sky = pow(clamp(input.light.y, 0.0, 1.0), 2.0);
    let block = pow(clamp(input.light.x, 0.0, 1.0), 2.0);
    let cool = vec3<f32>(0.46, 0.57, 0.70) * sky * (0.10 + 0.70 * day);
    let warm = vec3<f32>(1.0, 0.46, 0.17) * block;
    var color = input.color.rgb * (cool + warm + vec3<f32>(0.015));
    var opacity = input.color.a * 0.66;
    if input.snow {
        color = input.color.rgb * (cool * 1.5 + warm + vec3<f32>(0.035));
        opacity = input.color.a * 0.90;
    }
    return vec4<f32>(ss_fog(color, input.position), opacity);
}
