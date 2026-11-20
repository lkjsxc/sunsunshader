// SPDX-License-Identifier: Apache-2.0
// Pack-owned reserved smoothness semantic. Native Rgba32Uint preserves these
// finite float bits. Any future physical smoothness consumer must revise it.
const SS_HAZE_INWARD_EXPONENT: u32 = 0x00800000u;

struct SsHazeReceiver {
    valid: bool,
    positive: bool,
    strong: bool,
    block: f32,
    inward: bool,
}

fn ss_haze_encode_receiver(native_block: f32, inward: bool) -> f32 {
    let block = clamp(native_block, 0.0, 1.0);
    let flags = select(0u, 2u, block > 0.0) | select(0u, 1u, 15.0 * block > 8.0);
    let payload = min(bitcast<u32>((1.0 + block) * 0.5), 0x3f7ffffcu);
    // Use the [0.25, 0.5) exponent for an inward face. The mantissa and
    // receiver flags retain exactly the same bits as in [0.5, 1).
    let bits = (payload & 0xfffffffcu) | flags;
    return bitcast<f32>(bits - select(0u, SS_HAZE_INWARD_EXPONENT, inward));
}

fn ss_haze_decode_receiver(smoothness: f32, present: bool) -> SsHazeReceiver {
    let encoded = bitcast<u32>(smoothness);
    let inward = encoded >= 0x3e800000u && encoded < 0x3f000000u;
    let bits = encoded + select(0u, SS_HAZE_INWARD_EXPONENT, inward);
    let payload = bits & 0xfffffffcu;
    let positive = (bits & 2u) != 0u;
    let strong = (bits & 1u) != 0u;
    let valid = present && bits >= 0x3f000000u && bits <= 0x3f7fffffu
        && (!strong || positive) && (positive || payload == 0x3f000000u);
    if !valid { return SsHazeReceiver(false, false, false, 0.0, false); }
    return SsHazeReceiver(true, positive, strong, clamp(2.0 * bitcast<f32>(payload) - 1.0, 0.0, 1.0), inward);
}
