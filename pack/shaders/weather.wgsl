// Copyright 2026 Sunsun Shader contributors. SPDX-License-Identifier: Apache-2.0
fn weather(source: WeatherInput) -> vec4<f32> {
    var input = source;
    // API 0.1 supplies unlit gamma texture colour and a separate column light.
    input.color = vec4<f32>(ss_decode(source.color.rgb), source.color.a);
    let day = ss_daylight();
    let sky = pow(clamp(input.light.y, 0.0, 1.0), 2.0);
    let block = pow(clamp(input.light.x, 0.0, 1.0), 2.0);
    let cool = vec3<f32>(0.46, 0.57, 0.70) * sky * (0.80 * day + 0.012 * ss_moonlight());
    let warm = vec3<f32>(1.0, 0.46, 0.17) * block;
    let streak_luma = dot(input.color.rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    // Preserve the native streak texture and alpha, but relight its normalized
    // intensity. Multiplying the intrinsically dark blue atlas made rain look
    // like suspended black marks against the overcast horizon.
    let intensity = clamp(streak_luma * 4.0, 0.20, 1.0);
    let diffuse = vec3<f32>(0.30, 0.38, 0.48)
        * sqrt(sky) * (day + 0.012 * ss_moonlight());
    var color = intensity * (diffuse + warm * 0.65);
    let distance_fade = 1.0 - smoothstep(14.0, 28.0, length(input.position));
    var opacity = input.color.a * 0.45 * distance_fade;
    if input.snow {
        color = input.color.rgb * (cool * 1.5 + warm);
        opacity = input.color.a * 0.90;
    }
    return vec4<f32>(ss_encode(ss_fog(color, input.position, input.light.y)), opacity);
}
