# Native timing fixture provenance

`native-bench-5ef7734.json` is a **synthetic** example of the pinned Horizon
control reply. Its values are hand-chosen for exact nearest-rank and paired
reduction checks. It is not a device measurement. Tests construct synthetic
capture, admission and clean-pin receipt wrappers in temporary directories;
no real private captures, world data or hardware logs are checked in.

The format was checked against unmodified Horizon source revision
`5ef7734fdd854add5efd6817178be3c988d8d050`:

- [FrameStats](https://github.com/horizon-rust/horizon/blob/5ef7734fdd854add5efd6817178be3c988d8d050/crates/horizon-client/src/control.rs)
  retains `frame_ms`, `cpu_ms`, and asynchronous `gpu_ms`. Frame statistics use
  nearest-rank percentiles; `seconds` is the sum of elapsed frames divided by
  1000. The three arrays need not have equal lengths. Collection has a finite
  buffer, so the reducer refuses a saturated record.
- [Control protocol](https://github.com/horizon-rust/horizon/blob/5ef7734fdd854add5efd6817178be3c988d8d050/crates/horizon-client/src/game/runtime/control.rs)
  resets only FrameStats for `bench`; it attaches nonempty `gpu_passes` and
  `shader_passes` maps from the renderer. `simulation` supplies authoritative
  world `game_time`.
- [Pass timer](https://github.com/horizon-rust/horizon/blob/5ef7734fdd854add5efd6817178be3c988d8d050/crates/horizon-client-render/src/gfx/pack_timing.rs)
  collects timestamps asynchronously, retains a window of at most 15 observations
  for each name, and emits its median. Missing later observations do not evict
  a pass's old history. Repeated occurrences of a name within one timed frame
  are summed by the native timer. `bench raw` exposes neither these per-frame
  pass observations nor their counts/ages. No reducer can reconstruct them.
- [Native stage labels](https://github.com/horizon-rust/horizon/blob/5ef7734fdd854add5efd6817178be3c988d8d050/crates/horizon-shader-api/src/check.rs)
  use `name`, otherwise `file`. For the rc5 graph this yields 15 pack-stage names,
  including the before-world compute stage, sky and display stage. Material,
  vertex and weather execution is inside the renderer's draws; the two native
  shadow-map passes are in `gpu_passes`, not `shader_passes`.
- [Native frame uniforms](https://github.com/horizon-rust/horizon/blob/5ef7734fdd854add5efd6817178be3c988d8d050/crates/horizon-client-render/src/gfx/native_post.rs)
  use frozen world game time under `HORIZON_STILL`, after an admission screenshot's
  separate scripted clock ends. The screenshot resets kept history, so the
  benchmark warms afterward. The gallery timing path uses exact setup tick
  counts rather than wall-clock-dependent unfreezes.

The minimal required renderer set applies to Sunsun's current native graph with
shadows enabled and opaque-buffer-reading material: `World`, `World after copy`,
`Native shader pack shadow`, `Native shader pack translucent shadow`. Other
renderer passes are conditional. The reducer compares the complete observed
keysets across like-for-like runs; it does not assume that every possible
renderer pass must appear in every scene.

The tests cover raw-data arithmetic, unequal asynchronous GPU sample counts,
balanced block pairing, raw preservation, incomplete/reordered schedules,
changed metadata or activation, missing passes, corrupted hashes, nonfinite
values, duplicate JSON keys, cleanup failures and exact frozen-clock stepping.
The pin-receipt fixture exercises `gallery-pin.py`'s actual admission checks;
it is not a replacement for the real `release.py check --self-test` gate or
signed-distribution verification before a hardware run.
