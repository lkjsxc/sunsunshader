// SPDX-License-Identifier: Apache-2.0
// rc3's filmic curve remains the last post pass, at the same resolution.
// An explicit identity output mapping prevents an additional engine tone curve.
// Horizon clamps to display headroom and performs output encoding exactly once.
fn tonemap(input: TonemapInput) -> vec3<f32> {
    return input.color;
}
