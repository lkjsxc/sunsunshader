# SPDX-License-Identifier: Apache-2.0
"""W0: CPU projective witness for camera motion blur's previous_clip.w = 0 guard.

Independent of Sunsun's WGSL: it follows Horizon 5ef7734's documented reprojection
contract (docs/api/shaders-reference-0.2.md, previous_view_projection and
camera_motion; motion_at returns MOTION_NO_HISTORY where clip.w <= 0). With a
perspective projection clip.w is the point's depth along the previous view axis,
so only directions, depths and the camera pair matter. Pixel centres at 1920x1080,
vertical FOV 70 (gallery fov), view bob off.
"""
import json
import math
import sys

import numpy as np

W, H, VFOV = 1920, 1080, 70.0
TAN_V = math.tan(math.radians(VFOV / 2))
TAN_H = TAN_V * W / H
FADE = 0.1  # candidate fade: facing = w / distance; smoothstep(0, FADE, facing)


def rays():
    x = (np.arange(W) + 0.5) / W * 2 - 1
    y = 1 - (np.arange(H) + 0.5) / H * 2
    X, Y = np.meshgrid(x * TAN_H, y * TAN_V)
    d = np.stack([X, Y, -np.ones_like(X)], -1)  # current view space, forward -z
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def rotation(axis, degrees):
    a = np.asarray(axis, float)
    a /= np.linalg.norm(a)
    t = math.radians(degrees)
    k = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(t) * k + (1 - math.cos(t)) * k @ k


def classify(points, prev_forward, prev_eye):
    rel = points - prev_eye
    w = rel @ prev_forward
    facing = w / np.linalg.norm(rel, axis=-1)
    seam = (np.diff(w > 0, axis=0) != 0).sum() + (np.diff(w > 0, axis=1) != 0).sum()
    return {"w_le_0_px": int((w <= 0).sum()), "facing_lt_fade_px": int((facing < FADE).sum()),
            "seam_neighbour_pairs": int(seam)}


def rotate_case(d, axis, degrees):
    # The camera turned by +degrees about axis since last frame: last frame's forward is
    # this frame's forward turned back. Depth is irrelevant to the sign; use distance 10.
    prev_forward = rotation(axis, -degrees) @ np.array([0.0, 0.0, -1.0])
    return classify(d * 10.0, prev_forward, np.zeros(3))


def threshold(d, axis, limit):
    lo, hi = 0.0, 179.0
    for _ in range(40):
        mid = (lo + hi) / 2
        lo, hi = (lo, mid) if rotate_case(d, axis, mid)[limit] else (mid, hi)
    return round(hi, 3)


def ground_and_wall(d, eye_height=1.62, wall_distance=None, wall_lateral=None):
    """Distances along each ray to a ground plane, optional facing wall and side walls."""
    t = np.full(d.shape[:2], 1e4)
    down = d[..., 1] < 0
    t[down] = np.minimum(t[down], eye_height / -d[..., 1][down])
    if wall_distance is not None:
        t = np.minimum(t, np.where(d[..., 2] < 0, wall_distance / -d[..., 2], 1e4))
    if wall_lateral is not None:
        side = np.abs(d[..., 0]) > 0
        t = np.minimum(t, np.where(side, wall_lateral / np.abs(d[..., 0]), 1e4))
    return d * t[..., None]


def main():
    d = rays()
    forward = np.array([0.0, 0.0, -1.0])
    corner = np.cross(forward, d[0, -1])  # turning toward the top-right corner
    out = {"size": [W, H], "vfov": VFOV, "half_h_deg": round(math.degrees(math.atan(TAN_H)), 3),
           "half_diag_deg": round(math.degrees(math.atan(math.hypot(TAN_H, TAN_V))), 3),
           "fade_facing": FADE}
    out["first_w_le_0_deg_per_frame"] = {
        "yaw": threshold(d, [0, 1, 0], "w_le_0_px"),
        "pitch": threshold(d, [1, 0, 0], "w_le_0_px"),
        "toward_corner": threshold(d, corner, "w_le_0_px")}
    out["first_fade_change_deg_per_frame"] = {
        "yaw": threshold(d, [0, 1, 0], "facing_lt_fade_px"),
        "toward_corner": threshold(d, corner, "facing_lt_fade_px")}
    yaw = out["first_w_le_0_deg_per_frame"]["toward_corner"]
    out["deg_per_second_needed"] = {f"{fps}fps": round(yaw * fps) for fps in (60, 30, 20, 10, 7)}
    cases = {}
    for name, axis, deg in (("yaw_30", [0, 1, 0], 30), ("yaw_45", [0, 1, 0], 45),
                            ("yaw_60", [0, 1, 0], 60), ("corner_40", corner, 40)):
        cases[name] = rotate_case(d, axis, deg)
    # Seam column for pure yaw: x_ndc = cot(theta) / tan_h.
    cases["yaw_60"]["predicted_seam_x_px"] = round((1 / math.tan(math.radians(60)) / TAN_H + 1) / 2 * W, 1)
    prev_forward = rotation([0, 1, 0], -60) @ forward
    sides = (d * 10.0) @ prev_forward > 0
    # Rotation sign puts the w <= 0 side on the left here; mirror the prediction to match.
    cases["yaw_60"]["measured_seam_x_px"] = sorted({int(np.argmax(row)) for row in sides})
    cases["yaw_60"]["mirrored_prediction_px"] = round(W - cases["yaw_60"]["predicted_seam_x_px"], 1)
    # Translations: prev_eye is last frame's eye in this frame's camera-relative space.
    open_field = ground_and_wall(d)
    tunnel = ground_and_wall(d, wall_lateral=0.5, wall_distance=6.0)  # centred in a 1-wide corridor
    trans = {
        # Ordinary motion: the camera moved forward, sideways or up.
        "sprint_fly_forward_0.36": (open_field, [0, 0, 0.36]),
        "sprint_fly_strafe_0.36": (open_field, [0.36, 0, 0]),
        "elytra_forward_2.0": (open_field, [0, 0, 2.0]),
        # Backward: last frame's eye was ahead (-z) of this one.
        "walk_back_60fps_0.072_tunnel": (tunnel, [0, 0, -0.072]),
        "walk_back_10fps_0.43_tunnel": (tunnel, [0, 0, -0.43]),
        "walk_back_7fps_0.64_tunnel": (tunnel, [0, 0, -0.64]),
        "third_person_cut_4.0": (open_field, [0, 0, -4.0]),
    }
    for name, (points, eye) in trans.items():
        cases[name] = classify(points, forward, np.array(eye, float))
    out["cases"] = cases
    json.dump(out, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
