# Compatibility and release tools

Python 3.11+, Git and stable Rust are required.

```sh
python3 tools/release.py check --self-test
python3 tools/release.py build
python3 tools/release.py check dist/sunsunshader-0.2.0-rc7.hshader
```

Both `check` without an archive and `build` package `pack/` and check the
result for the pinned public Horizon Nightly. Outputs go to `dist/` by default.
The tool verifies the Horizon source tag, revision and audited ordinary-game
admission source in `compatibility/horizon.json`. It builds Horizon’s own
validator with its lockfile and checks the actual archive. The ordinary-game
admission gate enforces the pinned renderer’s API and manifest restrictions.
The self-test checks refusal of unknown manifest fields, obsolete API 0.1, a
motion stage and BT.2020 frame primaries.

Set `SUNSUN_NIGHTLY_SOURCE` to the absolute path of an existing clean checkout
to reuse the verified source. Otherwise the tool fetches the pin into
`.build/horizon-nightly`. Validator and post continuity build outputs are under
`.build/`. `CARGO_BUILD_JOBS` can lower the default cap of twelve jobs.

The `.check.json` receipt records the archive digest, pinned source, validator
hash, ordinary-game admission, and post continuity evidence. The `.sha256`
sidecar records the digest for the checked file. An existing archive can be
checked by passing it to `check`.

Publication uses `release.py release` after hardware admission and review. It
checks a snapshot of the supplied archive, rebuilds from `pack/` and requires
byte identity, committed and pushed `main`, and agreement with any existing
version tag. `--latest` selects GitHub Latest for the current public Nightly.
Publishing also requires an authenticated `gh`.

## Gallery and private timing tools

`gallery-pin.py` binds a clean pack validation receipt to the version-signed
Horizon distribution. `gallery-capture.py` uses those exact inputs in an isolated
offline game and private display. `gallery_timing.py plan|run|reduce` schedules
paired ABBA/BAAB gallery runs and reduces the pinned native benchmark format.
Raw evidence stays private; missing passes, metadata and interrupted schedules
are refused. Per-pass values are rolling endpoint timestamp medians, not raw
per-frame pass arrays or presented FPS.

The full operator procedure, idle-slot command and interpretation limits are in
[gallery-capture.md](../docs/gallery-capture.md#private-native-timing-comparisons).
Local fixture tests need only Python:

```sh
python3 -m unittest discover -s tools -p 'test_gallery_timing.py' -v
```

## Post-stage continuity check

The checker runs `horizon_shader_api::check` with the pinned Horizon source
and its vendored Naga 30.0.1. It traces image and kept-buffer values through
the validated IR of Compose and Display, starting at Horizon's own fragment
entries. It follows calls into pack-owned functions, including
`ss_world_bound`. Frame values, geometry and overrides can drive hard choices.
Image values can feed the checked arithmetic and the resolved linear sampler.
Image-driven branches, selections and discrete taps require a registered
boundary. The scope covers the pack-owned code reached in these two stages.

`post_continuity.json` pins the functions for the Compose, Focus and Lens
boundaries by SHA-256 of their canonical IR. Function-local references use
their arena positions. Module references resolve to names and canonical types,
and the print excludes source spans. For finite operands and a positive lens
band, the lens blend agrees with the Y and X tap pairs at weights 0 and 1.
Focus agrees with the incoming color at weight 0 and the filtered color at
weight 1.

`release.py check` runs the continuity checker directly on `pack/` before
packaging. Its `post_ir` receipt records the scanned roots and functions,
three registered boundaries, zero inherited exceptions, resolved bindings
and dependency pins.
Set `SUNSUN_NIGHTLY_SOURCE` to reuse a local checkout of the pinned source.
The tool verifies the tag, clean source, resolved Cargo paths, Naga features
and dependency lock before building.

The budget distinguishes draw passes, compute entries, kept resources and
plain outputs. Target costs are in sixteenths of a render-size RGBA16F target.
Expression and texture-read counts come from Horizon's checker.

For motion, the policy binds the camera proof to Horizon Nightly `5ef7734`.
The renderer supplies `previous_view_projection = perspective * bob * spin *
view` and `camera_motion = current_eye - previous_eye`. The prelude
reconstructs the current camera-relative point from reverse depth by
unprojecting and applying the inverse view rotation. In the unbobbed,
undistorted case `w / length(previous)` is the facing cosine. With camera
effects the shader uses the actual posed clip depth instead.

Let `d = max(length(previous), 1e-6)`. The fade uses the real clip `w`;
the tap projection divides by `max(w, 0.002*d)` only on the positive-fade
arm. The floor prevents overflow inside the pixel-space length, where the
inherited division can still overflow even with positive fade. With finite
stock camera inputs, a vertical FOV of 1–179 degrees, and a pose with linear
norm at most 4 and translation length at most 0.125 blocks, the proof covers
positive target sizes within the device's `max_texture_dimension_2d` on both
frames, for devices with a limit of at most 32768. Horizon carries history
across resize, so the previous projection's aspect can differ from the current
target's. The perspective focal scale is below 116, and the previous aspect's
reciprocal and current target width are each at most 32768. With
`length(posed_previous)/d <= 4 + 0.125/1e-6`, this bounds either uncapped pixel
component below `1.2e18`, using
`0.15 * 116 * 32768² * (4 + 0.125/1e-6) / 0.002` plus the UV centering term.
Both squares and their sum fit in f32. The tap displacement is at most 12
pixels in real arithmetic.

Below the previous-view horizon, fade zero returns the center without
projecting. At the seam the contribution of the bounded full blur tends to
zero, even where the taps differ from the center. Per channel the real
arithmetic change is bounded by `0.8 * fade * local_tap_span`. At fade one
the floor is inactive and the shortcut keeps the previous divisor, tap order,
and five-tap average. The receipt covers these boundaries within the finite
stock camera envelope. Projections outside that envelope, invalid upstream
inputs, and moving renderer looks remain outside the proof.

W0 independently checks the unbobbed camera geometry at 1920×1080 and a
70-degree vertical FOV. The separate f32 check exercises reverse-depth
reconstruction, camera effects, seam arithmetic, a carried projection across
resize, and the inherited overflow.
Both CPU witnesses use NumPy. Recorded moving clips provide runtime look
evidence. Horizon's frozen screenshot sequences hold the camera fixed.

```sh
python3 tools/post_ir.py check
python3 -m unittest discover -s tools -p 'test_post_continuity.py' -v
python3 tools/projective_w0.py
python3 tools/check_motion_fade.py
```
