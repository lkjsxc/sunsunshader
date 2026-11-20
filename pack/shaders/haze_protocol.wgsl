// SPDX-License-Identifier: Apache-2.0
// Haze look r2 storage protocol. Pure helpers: no kept resource is referenced here.
const SS_HAZE_MAGIC: u32 = 0x53484c31u;
const SS_HAZE_SCHEMA: u32 = 2u;
const SS_HAZE_HEADER_OK: u32 = 1u;
const SS_HAZE_R_COUNT: u32 = 32768u;
const SS_HAZE_E_COUNT: u32 = 262144u;
const SS_HAZE_A_R: u32 = 16u;
const SS_HAZE_A_E: u32 = 393232u;
const SS_HAZE_B_R: u32 = 4u;
const SS_HAZE_B_E: u32 = 131076u;
const SS_HAZE_B_AIR: u32 = 1179652u;
// Former SKY colour region: all masks are vec4(bits, world_epoch, frame_index, schema).
// Top bit i covers leaf (top*32+i); leaf bit j covers receiver slot (leaf*32+j).
// 32+1024 records fit inside the original 32768-record allocation.
const SS_HAZE_B_SKY_TOP: u32 = 1212420u;
const SS_HAZE_B_SKY_LEAF: u32 = 1212452u;
const SS_HAZE_SKY_TOP_COUNT: u32 = 32u;
const SS_HAZE_SKY_LEAF_COUNT: u32 = 1024u;
const SS_HAZE_SKY_CAMERA_INNER: f32 = 16.0;
const SS_HAZE_SKY_CAMERA_OUTER: f32 = 24.0;
const SS_HAZE_UNKNOWN: u32 = 0u;
const SS_HAZE_LIVE: u32 = 1u;
const SS_HAZE_ZERO: u32 = 2u;
const SS_HAZE_AMBIGUOUS: u32 = 3u;
const SS_HAZE_EXPIRED: u32 = 4u;
const SS_HAZE_STATE_MASK: u32 = 7u;
const SS_HAZE_CURRENT: u32 = 8u;
const SS_HAZE_MIXED_FACE: u32 = 32u;
const SS_HAZE_HAS_ZERO: u32 = 1u;
const SS_HAZE_HAS_POSITIVE: u32 = 2u;
const SS_HAZE_HAS_STRONG: u32 = 4u;
const SS_HAZE_E_BAD_GEOMETRY: u32 = 256u;
const SS_HAZE_E_WITNESS: u32 = 65536u;
const SS_HAZE_FIELD_SUPPORTED: u32 = 1u;
const SS_HAZE_FIELD_RETAINED: u32 = 2u;
const SS_HAZE_FIELD_INCOMPLETE: u32 = 4u;
const SS_HAZE_HOLD: f32 = 2.0;
const SS_HAZE_DEAD: f32 = 8.0;
const SS_HAZE_RANGE_INNER: f32 = 20.0;
const SS_HAZE_RANGE_OUTER: f32 = 28.0;
const SS_HAZE_REACH: f32 = 7.0;
// Deliberately uncalibrated; one gain is calibrated only by the frozen matched ablation.
const SS_HAZE_GAIN: f32 = 1.0;

struct SsHazeCamera {
    valid: bool,
    integer: vec3<i32>,
    fraction: vec3<f32>,
    origin: vec3<i32>,
}

fn ss_haze_camera() -> SsHazeCamera {
    let p = frame.camera_position;
    if !all(abs(p) < vec3<f32>(1073741824.0)) {
        return SsHazeCamera(false, vec3<i32>(0), vec3<f32>(0.0), vec3<i32>(0));
    }
    let integer = vec3<i32>(floor(p));
    let remainder = vec3<i32>(bitcast<vec3<u32>>(integer) & vec3<u32>(1u));
    let quotient = (integer - remainder) / vec3<i32>(2);
    return SsHazeCamera(true, integer, p - vec3<f32>(integer), quotient - vec3<i32>(16));
}

fn ss_haze_local_position_valid(p: vec3<f32>) -> bool {
    return all(abs(p) < vec3<f32>(96.0));
}

fn ss_haze_active_r(key: vec3<i32>, camera: SsHazeCamera) -> bool {
    return camera.valid && all(key >= camera.origin) && all(key < camera.origin + vec3<i32>(32));
}

fn ss_haze_active_e(key: vec3<i32>, camera: SsHazeCamera) -> bool {
    let origin = camera.origin * vec3<i32>(2);
    return camera.valid && all(key >= origin) && all(key < origin + vec3<i32>(64));
}

fn ss_haze_r_index(key: vec3<i32>) -> u32 {
    let p = bitcast<vec3<u32>>(key) & vec3<u32>(31u);
    return p.x + 32u * p.y + 1024u * p.z;
}

// Invert one absolute toroidal receiver slot into its unique full key in this
// active window. Callers prove slot<32768; the modulo never substitutes for
// subsequent active-window/full-key/epoch validation.
fn ss_haze_r_slot_key(slot: u32, camera: SsHazeCamera) -> vec3<i32> {
    let coordinates = vec3<u32>(slot & 31u, (slot >> 5u) & 31u, slot >> 10u);
    let origin = bitcast<vec3<u32>>(camera.origin) & vec3<u32>(31u);
    let offset = (coordinates + vec3<u32>(32u) - origin) & vec3<u32>(31u);
    return camera.origin + vec3<i32>(offset);
}

fn ss_haze_e_index(key: vec3<i32>) -> u32 {
    let p = bitcast<vec3<u32>>(key) & vec3<u32>(63u);
    return p.x + 64u * p.y + 4096u * p.z;
}

fn ss_haze_r_accum(key: vec3<i32>) -> u32 { return SS_HAZE_A_R + 12u * ss_haze_r_index(key); }
fn ss_haze_e_accum(key: vec3<i32>) -> u32 { return SS_HAZE_A_E + 11u * ss_haze_e_index(key); }
fn ss_haze_r_record(key: vec3<i32>) -> u32 { return SS_HAZE_B_R + 4u * ss_haze_r_index(key); }
fn ss_haze_e_record(key: vec3<i32>) -> u32 { return SS_HAZE_B_E + 4u * ss_haze_e_index(key); }

fn ss_haze_child(index: u32) -> vec3<i32> {
    return vec3<i32>(i32(index & 1u), i32((index >> 1u) & 1u), i32((index >> 2u) & 1u));
}

fn ss_haze_r_lower(p: vec3<f32>, camera: SsHazeCamera) -> vec3<i32> {
    let remainder = vec3<i32>(bitcast<vec3<u32>>(camera.integer) & vec3<u32>(1u));
    let quotient = (camera.integer - remainder) / vec3<i32>(2);
    let local = (vec3<f32>(remainder) + camera.fraction + p) * 0.5;
    return quotient + vec3<i32>(floor(local));
}

fn ss_haze_r_relative(key: vec3<i32>, camera: SsHazeCamera) -> vec3<f32> {
    return vec3<f32>(key * vec3<i32>(2) - camera.integer) - camera.fraction;
}

fn ss_haze_e_relative(key: vec3<i32>, offset: vec3<f32>, camera: SsHazeCamera) -> vec3<f32> {
    return vec3<f32>(key - camera.integer) + offset - camera.fraction;
}

// A tangential face gives no sided ownership at a grid edge. Depth
// reconstruction can land just across that edge in the adjacent block.
fn ss_haze_e_witness_unambiguous(p: vec3<f32>, normal: vec3<f32>, camera: SsHazeCamera) -> bool {
    let relative = p + camera.fraction;
    let near_edge = abs(relative - round(relative)) <= vec3<f32>(1.0 / 2048.0);
    let tangent = abs(normal) < vec3<f32>(1.0 / 64.0);
    return !any(select(vec3<bool>(false), near_edge, tangent));
}

fn ss_haze_e_key(p: vec3<f32>, normal: vec3<f32>, inward: bool, camera: SsHazeCamera) -> vec3<i32> {
    // Bias toward the block that owns the observed face.
    let bias = select(1.0 / 1024.0, -1.0 / 1024.0, inward);
    return camera.integer + vec3<i32>(floor(camera.fraction + p - normal * bias));
}

fn ss_haze_key_equal(stored: vec3<u32>, expected: vec3<i32>) -> bool {
    return all(stored == bitcast<vec3<u32>>(expected));
}

fn ss_haze_fresh(age: f32) -> f32 {
    return 1.0 - smoothstep(SS_HAZE_HOLD, SS_HAZE_DEAD, clamp(age, 0.0, SS_HAZE_DEAD));
}

fn ss_haze_advance_age(age: f32, elapsed: f32) -> f32 {
    if !(age >= 0.0 && age <= SS_HAZE_DEAD) { return SS_HAZE_DEAD; }
    return min(age + elapsed, SS_HAZE_DEAD);
}

// Native ordinary time is elapsed seconds modulo 3600. This preserves a short
// pause even when delta_time is zero. Gaps >=3600 seconds are inherently aliased;
// HORIZON_STILL/scripted timing is virtual time, not a wall-clock assertion.
fn ss_haze_clock_delta(previous: f32) -> f32 {
    if !(previous >= 0.0 && previous < 3600.0 && frame.time >= 0.0 && frame.time < 3600.0) {
        return SS_HAZE_DEAD;
    }
    var elapsed = frame.time - previous;
    if elapsed < 0.0 { elapsed += 3600.0; }
    return min(elapsed, SS_HAZE_DEAD);
}

fn ss_haze_range(p: vec3<f32>) -> f32 {
    let distance = max(abs(p.x), max(abs(p.y), abs(p.z)));
    return 1.0 - smoothstep(SS_HAZE_RANGE_INNER, SS_HAZE_RANGE_OUTER, distance);
}

fn ss_haze_transfer(level: f32) -> f32 {
    let t = clamp((level - 8.0) / 6.0, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn ss_haze_face(normal: vec3<f32>) -> u32 {
    let a = abs(normal);
    var axis = 0u;
    if a.y > a.x { axis = 1u; }
    if a.z > a[axis] { axis = 2u; }
    return axis * 2u + select(0u, 1u, normal[axis] >= 0.0);
}

fn ss_haze_mixed_faces(evidence: u32) -> bool {
    let faces = (evidence >> 8u) & 63u;
    return (faces & (faces - select(0u, 1u, faces != 0u))) != 0u;
}

// Same representation as the pinned native surface target, two signed-normalized
// octahedral coordinates. This decodes the actual stored witness normal.
fn ss_haze_unpack_normal(packed: u32) -> vec3<f32> {
    let e = unpack2x16snorm(packed);
    var n = vec3<f32>(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
    if n.y < 0.0 {
        n = vec3<f32>((1.0 - abs(n.z)) * sign(n.x), n.y, (1.0 - abs(n.x)) * sign(n.z));
    }
    return normalize(n);
}

fn ss_haze_axis_sample(pixel: u32, length: u32, maximum: u32, multiple: bool) -> bool {
    if length == 0u { return false; }
    let bins = min(length, maximum);
    let quotient = length / bins;
    let remainder = length % bins;
    let prefix = remainder * (quotient + 1u);
    var first = 0u;
    var span = quotient;
    if pixel < prefix {
        first = (pixel / (quotient + 1u)) * (quotient + 1u);
        span += 1u;
    } else {
        first = prefix + ((pixel - prefix) / quotient) * quotient;
    }
    if !multiple { return pixel == first + span / 2u; }
    let half = span / 2u;
    let a = first + half / 2u;
    let b = first + half + (span - half) / 2u;
    return pixel == a || pixel == b;
}

fn ss_haze_splat_weight(fraction: vec3<f32>, corner: vec3<i32>) -> f32 {
    let w = select(vec3<f32>(1.0) - fraction, fraction, corner != vec3<i32>(0));
    return w.x * w.y * w.z;
}

fn ss_haze_quantize(q: u32, value: f32) -> u32 {
    return u32(round(f32(q) * clamp(value, 0.0, 1.0)));
}
