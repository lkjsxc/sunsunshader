# Sunsun Shader 0.2.0-rc1

A pre-release of the original native Horizon pack: directional sun and moon shadows,
clear blue daylight, coloured shade, layered clouds, reflective water and warm local light.

## Install

This archive targets **Horizon Nightly 2026-11-13 · 9f42064**, the public launcher
Nightly for Minecraft Java Edition 26.3, using shader API **0.1**.

Put `sunsunshader-0.2.0-rc1.hshader` in the game's `shaderpacks/` folder and select
**Sunsun Shader** under Options → Video Settings → Shaders → Shader Packs. Keep one
installed Sunsun file. Folder installation also works as `shaderpacks/sunsunshader/`.
No experimental HDR environment switch is required. The archive is a release candidate;
version 0.1.1 remains available if you prefer the previous appearance or lower cost.

## Profiles and options

**Medium is the default.** Low reduces procedural cloud sampling, uses four shadow
filter samples, omits screen contact shading and reflects the atmosphere in water.
Medium adds eight-sample contact depth, reflected cloud volumes and screen-space
shore reflections. High increases cloud, shadow and reflection sampling and enables
the depth-limited light-shaft integral. All three use the real sun/moon shadow map.

Controls cover exposure, air density, clouds, shadows, terrain reflections, contact
shading, plant wind, weather detail and bloom. Depth of field, camera motion blur
and vignette are off by default. Wind is used in both terrain and shadow vertices.
The declared 4 ms budget at 1920×1080 is a design target, not a measured GPU result;
see the project report for same-machine software frame-time comparisons.

## Public Nightly limits

The ordinary Nightly has no pack entity material stage. Entities retain engine
lighting and their offscreen shadow casters can disappear through native culling.
Screen-space water reflections lose terrain outside the screen; misses use the same
original sky and cloud field. A native mirror exists but has no exposed terrain mask,
so it cannot supply a coherent custom-sky fallback. Waves change normals and refraction,
not the water mesh. Depth and the bed pattern are approximations.

The native world frame is bounded gamma colour. Source shoulders preserve as much
colour and texture as possible before post processing, but cannot provide a true HDR
world buffer. Transparent surfaces still blend in native gamma space. The pack retains
the native moon phase texture with an added halo; 0.1 exposes no moon-off control or
phase value. Existing block-light levels provide local falloff and wall occlusion;
there are no local-light shadow maps or general bounce-light transport.

Contact shading sees only visible solid terrain. Clouds use bounded procedural
quadrature and can simplify in the distance. Snow and auroras use the camera biome.
Temporal accumulation and object motion blur are absent. Some native draws can
receive additional post fog.

The [project README](https://github.com/lkjsxc/sunsunshader) contains the exact
compatibility pin, current pictures, profile cost, remaining weaknesses and build
instructions. The separately maintained API0.2 development variant has not been
promoted to this public Nightly release.

All shader code is original and licensed under Apache-2.0. Published mathematical
methods are credited in source comments; no other shader pack is used as source.
