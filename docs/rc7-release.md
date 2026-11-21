# Sunsun Shader 0.2.0-rc7 candidate

The folded pack targets Horizon Nightly 2026-11-19 (5ef7734) and shader API 0.2.
Medium is the default profile. Light in the air, depth of field, camera motion
blur and vignette are off by default.

- Compose combines bloom, camera blur and optional focus. Display applies edge
  resolve and filmic output. The manifest goes from 12 to 9 post entries and
  from 8 to 5 draw passes. Haze clear and Resolve specialize to empty bodies
  with Light in the air off.
- The rc6c edge and focus changes removed single-pixel flecks in the checked
  scenes. The earlier Fc-on-rc6c comparison across seven llvmpipe conditions at
  1920×1080 recorded mean differences of at most 0.0168 codes and peaks of 1–3
  codes. Archive member comparison and static inspection carry that evidence
  to this candidate's default motion-off path.
- With camera blur enabled, static checks show a continuous fade at the
  previous-view horizon within the finite stock camera envelope on devices
  with a maximum 2D texture dimension of at most 32768. The projection bound
  fits f32 even when the previous and current frames differ in size.

The pinned Horizon validator and ordinary-game admission pass on CPU. The
4 ms Medium budget at 1920×1080 remains a target. First RADV execution and
stock-relative timing still depend on the staged G2 run. The gallery shows rc5.
