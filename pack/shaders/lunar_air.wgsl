// SPDX-License-Identifier: Apache-2.0
// Original sky-only aureole measured from the native moon already in the
// untouched world picture. This is a visible-radiance estimate, not a lunar
// calendar or phase model, and it does not change surface moon illumination.
//
// Include this file only in the Air post. Add ss_visible_moon_air(direction)
// to the sky background BEFORE ss_cloud_composite. Remove the old unobserved
// lunar_haze term from ss_atmosphere, or it will survive on an unlit new moon.
//
// API evidence: the public Nightly draws the lunar quad at distance 100 with
// half-size 20. Its native 32px phase textures put the bright body in the
// central 8px, giving a body half-angle close to 0.05 radians. The +/-0.040
// samples cover the illuminated limbs as well as the centre without treating
// the faint grey border of the native new-moon texture as a light source.
// Different resource-pack body sizes/positions can reduce this estimate.

fn ss_lunar_project(direction: vec3<f32>) -> vec3<f32> {
    let eye = frame.view * vec4<f32>(direction, 0.0);
    let clip = frame.projection * eye;
    if clip.w <= 0.00001 { return vec3<f32>(0.0, 0.0, -1.0); }
    return vec3<f32>(clip.x / clip.w * 0.5 + 0.5,
        0.5 - clip.y / clip.w * 0.5, clip.w);
}

fn ss_visible_moon_air(direction: vec3<f32>) -> vec3<f32> {
    // No added work on Low, outside the Overworld, in another camera medium,
    // or in daylight. A native moon is still allowed to draw normally.
    let night = 1.0 - smoothstep(-0.16, -0.025, frame.sun_direction.y);
    if !local_haze || quality == 0u || frame.dimension != 0 || frame.eye_in != 0u
        || night <= 0.00001 || frame.moon_direction.y <= 0.0 || haze <= 0.0 {
        return vec3<f32>(0.0);
    }
    let moon = normalize(frame.moon_direction);
    let ray = normalize(direction);
    let cosine = clamp(dot(ray, moon), -1.0, 1.0);
    if cosine <= 0.70 { return vec3<f32>(0.0); }
    let centre = ss_lunar_project(moon);
    if centre.z <= 0.0 || any(centre.xy <= vec2<f32>(0.0))
        || any(centre.xy >= vec2<f32>(1.0)) {
        return vec3<f32>(0.0);
    }

    // Source discovery is necessarily on screen. Fade before the body reaches
    // the boundary instead of switching a wide halo off in one camera step.
    let edge = min(min(centre.x, 1.0 - centre.x), min(centre.y, 1.0 - centre.y));
    let edge_visibility = smoothstep(0.0, 0.055, edge);
    let reference = select(vec3<f32>(0.0, 1.0, 0.0),
        vec3<f32>(1.0, 0.0, 0.0), abs(moon.y) > 0.98);
    let horizontal = normalize(cross(moon, reference));
    let vertical = normalize(cross(horizontal, moon));
    let size = vec2<f32>(textureDimensions(scene_color));

    // The smooth atmospheric background varies little across this small body
    // footprint; one central evaluation avoids nine full atmospheric fits.
    // Stars/aurora are not in that background. Requiring separate lit samples
    // rejects a single bright stellar outlier, but is not perfect segmentation.
    let background = ss_atmosphere(moon);
    var body_radiance = vec3<f32>(0.0);
    var lit_samples = 0u;
    for (var y = -1i; y <= 1i; y += 1i) {
        for (var x = -1i; x <= 1i; x += 1i) {
            let sample_direction = normalize(moon
                + horizontal * (f32(x) * 0.040)
                + vertical * (f32(y) * 0.040));
            let projected = ss_lunar_project(sample_direction);
            if projected.z <= 0.0 || any(projected.xy <= vec2<f32>(0.0))
                || any(projected.xy >= vec2<f32>(1.0)) { continue; }
            let pixel = vec2<i32>(projected.xy * size);
            // Only visible sky qualifies. A lamp or bright roof covering the
            // projected lunar body must not become its apparent illumination.
            if textureLoad(scene_depth, pixel, 0) > 0.0000001 { continue; }
            let observed = ss_decode(textureSampleLevel(scene_color,
                linear_sampler, projected.xy, 0.0).rgb);
            let residual = max(observed - background, vec3<f32>(0.0));
            let luminance = dot(residual, vec3<f32>(0.2126, 0.7152, 0.0722));
            // Native new moon remains below this linear-light threshold.
            // It contributes exactly zero; it is not normalized into a lamp.
            if luminance <= 0.045 { continue; }
            lit_samples += 1u;
            body_radiance += residual * smoothstep(0.045, 0.10, luminance);
        }
    }
    if lit_samples < 2u { return vec3<f32>(0.0); }
    // Keep the total nine-sample divisor when the body is partly dark/hidden.
    // Normalizing only by surviving samples would brighten every crescent.
    body_radiance /= 9.0;

    let humidity = clamp(frame.downfall * 0.60 + frame.wetness * 0.65
        + frame.rain * 0.50, 0.0, 1.0);
    let low_moon = 1.0 - smoothstep(0.08, 0.55, moon.y);
    let moisture = (0.70 + humidity * 1.10) * haze;
    // Two normalized Henyey-Greenstein lobes give a soft core and wider damp
    // envelope. The tint stays close to the measured body; low air is modestly
    // warmer, rather than adding saturated blue to every dark sky direction.
    let core = ss_phase_aerosol(cosine, 0.88) / ss_phase_aerosol(1.0, 0.88);
    let wide = ss_phase_aerosol(cosine, 0.68) / ss_phase_aerosol(1.0, 0.68);
    let shape = core * 0.240 + wide * (0.063 + humidity * 0.0875);
    let tint = mix(vec3<f32>(0.80, 0.88, 1.0),
        vec3<f32>(1.0, 0.89, 0.74), low_moon * 0.28);
    let angular_fade = smoothstep(0.70, 0.82, cosine);
    let horizon_visibility = smoothstep(0.0, 0.075, moon.y);
    return body_radiance * tint * shape * moisture * night * edge_visibility
        * angular_fade * horizon_visibility;
}
