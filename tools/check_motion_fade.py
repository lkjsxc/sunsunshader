# SPDX-License-Identifier: Apache-2.0
"""CPU f32 checks for rc6d using Horizon's camera-relative reprojection."""

import json
import math

import numpy as np

from projective_w0 import rotation


F32 = np.float32
MAX_TEXTURE_DIMENSION_2D = 32768
MIN_SUBNORMAL = np.nextafter(F32(0), F32(1))


def projection(fov, resolution):
    """Horizon calls perspective_rh with the far and near planes reversed."""
    width, height = resolution
    focal = 1 / math.tan(math.radians(fov) / 2)
    near, far = 0.05, 2048.0
    return np.array([[focal * height / width, 0, 0, 0],
                     [0, focal, 0, 0],
                     [0, 0, near / (far - near), near * far / (far - near)],
                     [0, 0, -1, 0]], dtype=F32)


def affine(linear, offset=(0, 0, 0)):
    matrix = np.eye(4, dtype=F32)
    matrix[:3, :3], matrix[:3, 3] = linear, offset
    return matrix


def homogeneous(point, w):
    return np.array([*point, w], dtype=F32)


def reconstruct(uv, depth, current_projection, current_view):
    ndc = homogeneous((F32(2) * uv[0] - F32(1), F32(1) - F32(2) * uv[1],
                       max(depth, F32(0.000001))), 1)
    view_point = np.linalg.inv(current_projection) @ ndc
    return (np.linalg.inv(current_view) @ homogeneous(view_point[:3] / view_point[3], 0))[:3]


def length(point):
    return np.sqrt(np.sum(point * point, dtype=F32))


def capped_motion(uv, clip, divisor, resolution):
    old_uv = np.array([clip[0] / divisor * F32(0.5) + F32(0.5),
                       F32(0.5) - clip[1] / divisor * F32(0.5)], dtype=F32)
    motion = (uv - old_uv) * F32(0.30)
    pixels = length(motion * resolution)
    return motion * min(F32(1), F32(12) / max(pixels, F32(0.01)))


def picture(uv):
    x, y = np.clip(uv, F32(0), F32(1))
    # Bounded bilinear fixture with contrast and nonzero channels.
    return np.array([x, y, F32(0.25) + F32(0.5) * x * y], dtype=F32)


def full_blur(uv, motion):
    color = picture(uv)
    for index in range(1, 5):
        color += picture(uv - motion * (F32(index) / F32(4)))
    return color / F32(5)


def evaluate(uv, previous, clip, resolution):
    distance = max(length(previous), F32(0.000001))
    facing = clip[3] / distance
    t = np.clip(facing / F32(0.1), F32(0), F32(1))
    fade = t * t * (F32(3) - F32(2) * t)
    if fade == 0:
        return float(fade), 0.0

    divisor = max(clip[3], F32(0.002) * distance)
    motion = capped_motion(uv, clip, divisor, resolution)
    displacement = float(length(motion * resolution))
    assert 0 <= displacement <= 12.000004, displacement
    blurred = full_blur(uv, motion)
    if fade >= 1:
        assert divisor == clip[3]
        legacy = full_blur(uv, capped_motion(uv, clip, clip[3], resolution))
        assert blurred.tobytes() == legacy.tobytes()
    else:
        # The real-arithmetic fade changes each component by at most fade*4/5
        # of the local span. The fixture's entire span is <= 1, plus f32 error.
        center = picture(uv)
        blended = center * (F32(1) - fade) + blurred * fade
        assert np.all(np.abs(blended - center) <= 0.8 * fade + 2e-7)
    return float(fade), displacement


def matrix_cases():
    resolution = np.array([1920, 1080], dtype=F32)
    persp = projection(70, resolution)
    world = affine(rotation([0, 1, 0], 23))
    turned = affine(rotation([0, 1, 0], 60)) @ world
    bob = affine(rotation([1, 0, 0], 0.5), (0.03, -0.1, 0))
    rotate_spin = affine(rotation([0, 1, 1], 31))
    spin = rotate_spin @ np.diag(np.array([1, 2.7, 1, 1], dtype=F32)) @ rotate_spin.T
    variants = [
        ("held", persp, world, np.zeros(3, dtype=F32)),
        ("yaw", persp, turned, np.zeros(3, dtype=F32)),
        ("back_cut", persp, world, world[:3, :3].T @ np.array([0, 0, 4], dtype=F32)),
        ("bob_spin_turn", persp @ bob @ spin, turned, np.array([0.25, -0.08, 0.3], dtype=F32)),
    ]
    results = {}
    for name, previous_projection, previous_view, camera_motion in variants:
        current_projection = persp @ bob if name == "bob_spin_turn" else persp
        previous_vp = previous_projection @ previous_view
        counts = {"zero_fade": 0, "partial_fade": 0, "full_fade": 0}
        for u in np.linspace(0.001, 0.999, 33, dtype=F32):
            for v in np.linspace(0.001, 0.999, 9, dtype=F32):
                uv = np.array([u, v], dtype=F32)
                for depth in map(F32, (0, 0.0001, 0.01, 0.01247, 0.0125, 0.02, 0.1, 1)):
                    position = reconstruct(uv, depth, current_projection, world)
                    previous = position + camera_motion
                    clip = previous_vp @ homogeneous(previous, 1)
                    if name == "held":
                        assert np.allclose(clip[:2] / clip[3], [2 * u - 1, 1 - 2 * v], atol=3e-7)
                    fade, _ = evaluate(uv, previous, clip, resolution)
                    key = "zero_fade" if fade == 0 else "full_fade" if fade >= 1 else "partial_fade"
                    counts[key] += 1
        assert counts["full_fade"] and (name == "held" or all(counts.values())), (name, counts)
        results[name] = counts
    return results


def seam_cases():
    uv = np.array([0.7, 0.4], dtype=F32)
    edges = (0.002, 0.1, 0.002 * 1.25**0.5, 0.1 * (1.25 / 0.99)**0.5)
    depths = [MIN_SUBNORMAL, *np.geomspace(1e-38, 0.16, 128, dtype=F32)]
    depths.extend(F32(edge * side) for edge in edges for side in (0.999999, 1, 1.000001))
    widths = (-F32(0.16), -MIN_SUBNORMAL, F32(0), *depths)
    largest = (MAX_TEXTURE_DIMENSION_2D, MAX_TEXTURE_DIMENSION_2D)
    narrow = (1, MAX_TEXTURE_DIMENSION_2D)
    cases = [
        (70, (1920, 1080), (1920, 1080), (0, 0, 0), (1, 0.5)),
        (1, largest, largest, (0.05, -0.1, 0), (0, 0)),
        (1, narrow, narrow, (0.05, -0.1, 0), (0, 0)),
        # History retains the narrow projection when the target grows wider.
        (1, narrow, largest, (0.1118, 0, 0), (0, 0)),
    ]
    max_tap = 0.0
    resize_samples = 0
    resize_max_tap = 0.0
    for fov, previous_size, current_size, bob_offset, (x, y) in cases:
        resolution = np.asarray(current_size, dtype=F32)
        previous_vp = projection(fov, previous_size) @ affine(np.eye(3), bob_offset)
        for w in widths:
            previous = np.array([x, y, -w], dtype=F32)
            clip = previous_vp @ homogeneous(previous, 1)
            fade, displacement = evaluate(uv, previous, clip, resolution)
            if w <= 0:
                assert fade == 0
            max_tap = max(max_tap, displacement)
            if previous_size != current_size:
                resize_samples += 1
                resize_max_tap = max(resize_max_tap, displacement)
    assert resize_max_tap > 0

    resolution = np.array([1920, 1080], dtype=F32)
    previous = np.array([1, 0.5, -1e-19], dtype=F32)
    clip = projection(70, resolution) @ homogeneous(previous, 1)
    assert evaluate(uv, previous, clip, resolution)[0] > 0
    try:
        capped_motion(uv, clip, clip[3], resolution)
    except FloatingPointError as error:
        assert "overflow encountered in multiply" in str(error), error
    else:
        raise AssertionError("Inherited pixel-space length overflow control passed")
    return {"samples": len(cases) * len(widths), "maximum_tap_pixels_f32": max_tap,
            "resize_samples": resize_samples, "resize_maximum_tap_pixels_f32": resize_max_tap,
            "inherited_length_overflow_refused": True}


if __name__ == "__main__":
    with np.errstate(over="raise", invalid="raise", divide="raise", under="ignore"):
        print(json.dumps({"camera_matrix_cases": matrix_cases(), "seam_cases": seam_cases()}, indent=2))
