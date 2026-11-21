// SPDX-License-Identifier: Apache-2.0
// The last post is Compose. Apply the edge filter and filmic mapping in the
// mandatory display stage, preserving linear HDR before output encoding.
fn tonemap(input: TonemapInput) -> vec3<f32> {
    return ss_filmic(ss_edge_resolve(input.uv, input.color));
}
