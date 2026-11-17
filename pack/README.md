# Sunsun Shader

A native Horizon shader pack with warm daylight, cool shade, soft clouds and clear water.

## Install

Copy this folder into your game directory as `shaderpacks/sunsunshader/`, or install the packaged
`.hshader` there. Select **Sunsun Shader** under Options → Video Settings → Shaders → Shader Packs.
Keep one installed copy.

Requires experimental shader API **0.2**. Checked against Horizon
`5c9c56be8c14e42b8a32ac52aac53ce26e159ecc` for Minecraft Java Edition 26.3.

## Options

Medium is the default profile. Low reduces sampling and uses sky-only water reflections. High and Ultra add
longer screen-space searches and reflected cloud volumes. Exposure, air density, clouds, shadows, terrain
reflections, weather detail and bloom have individual controls.

Depth of field, camera motion blur and vignette are off by default. Ray reflections are also off by default
and require High or Ultra. This experimental path has not produced a verified hardware image; a Lavapipe
ray-enabled run crashed with an unresolved cause. The option gates queries only: Horizon may still maintain
a ray scene. `HORIZON_RAY_TRACING=0` disables that engine path entirely.

The declared 4 ms budget at 1920×1080 is a Medium design target, not a measured GPU result.

## Limits

The native moon retains its phase texture; custom orbits, eclipses and lightning inside clouds are absent.
Water uses normal waves and approximate caustics. Snow uses the camera biome. Temporal accumulation is absent.
Items and other native draws outside the material/entity paths can retain engine lighting or receive extra post fog.

Screenshots, the profile table and development instructions are in the
[project README](https://github.com/lkjsxc/sunsunshader).

All shader code is original and licensed under Apache-2.0. Published methods are credited in source comments.
