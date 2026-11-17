# Sunsun Shader 0.1.1

A native Horizon shader pack with warm daylight, cool shade, soft clouds and clear water.

## Install

Tested in **Horizon Nightly 2026-11-13 · 9f42064**, the public launcher Nightly,
for Minecraft Java Edition 26.3. This file uses the released game's shader API **0.1**.

Put `sunsunshader-0.1.1.hshader` into your game directory's `shaderpacks/` folder.
Select **Sunsun Shader** under Options → Video Settings → Shaders → Shader Packs.
Keep one installed copy. Folder installation also works: copy this folder as
`shaderpacks/sunsunshader/`. No experimental environment switch is required.

Use this file for Nightly 2026-11-13; the separate `-main.hshader` built from the
repository is for development builds using shader API 0.2.

## Options

Medium is the default profile. Low reduces sampling and uses sky-only water reflections.
High and Ultra add longer screen-space searches and reflected cloud volumes. Exposure,
air density, clouds, shadows, terrain reflections, weather detail and bloom have controls.
Depth of field, camera motion blur and vignette are off by default.

The declared 4 ms budget at 1920×1080 is a Medium design target, not a measured GPU result.

## Limits

This Nightly has no custom entity shading or material ray-query support: mobs, items,
particles and the hand retain engine lighting; water uses screen-space terrain reflections.
Its normal world framebuffer cannot carry HDR highlight energy. Bright pack colours keep
their hue but have dimmer cores and less bloom than the development variant. The native
moon also has a slightly stronger blue halo.
Native transparent draws blend in the game's gamma space.

The native moon retains its phase texture; custom orbits, eclipses and lightning inside
clouds are absent. Water uses normal waves and approximate caustics. Snow uses the camera
biome. Temporal accumulation is absent. Some native draws can receive additional post fog.
Clear clouds remain smooth and heavy rain can retain shallow-angle layering.

Screenshots, the profile table, exact compatibility pin and build instructions are in the
[project README](https://github.com/lkjsxc/sunsunshader).

All shader code is original and licensed under Apache-2.0. Published methods are credited
in source comments.
