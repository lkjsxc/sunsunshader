# Sunsun Shader 0.2.0-rc2

An original native Horizon pack with warm light in the air, dark unlit spaces,
directional shadows, clear blue daylight, layered clouds and reflective water.

## Install

This archive targets **Horizon Nightly 2026-11-13 · 9f42064**, the public launcher
Nightly for Minecraft Java Edition 26.3, using shader API **0.1**.

Put `sunsunshader-0.2.0-rc2.hshader` in the game's `shaderpacks/` folder and select
**Sunsun Shader** under Options → Video Settings → Shaders → Shader Packs. Keep one
installed Sunsun file. Folder installation also works as `shaderpacks/sunsunshader/`.
No experimental HDR environment switch is required. This is a release candidate;
previous releases remain available.

## Light and darkness

Medium and High add distance-dependent Overworld scattering from visible torches, lanterns,
lava and other emissive terrain. Warm light collects along the eye ray through
damp air; depth limits its reach. Night, low sun, rain, biome humidity and enclosed
space increase the effect. Clear open noon does not receive this local haze.

Unlit Overworld surfaces have no added ambient floor, decorative ore emission or cave
exposure boost. The player's brightness and vision settings remain available;
the pack's brightness adjustment multiplies existing light and preserves zero.
A broad lunar aureole follows the visible native moon pixels, including their
phase and obstruction, before the clouds are composited.

## Profiles and options

**Medium is the default.** The **Light in the air** option enables local and lunar
haze on Medium and High. Low retains optical bloom and skips the expensive air
sampling, while retaining the small pass/target overhead of the common graph.
Turn the option off to compare the air contribution directly.

Low uses fewer cloud and shadow samples, omits contact shading and reflects the
atmosphere in water. Medium adds reflected clouds, screen-space shore reflections,
two visible local sources per air sample and two source-path visibility checks.
High raises cloud, shadow and reflection sampling, uses up to three local sources
with four visibility checks, and adds the depth-limited daylight shaft integral.
All profiles use the real sun/moon shadow map.

Other controls cover exposure, air density, clouds, shadows, terrain reflections,
wave strength, contact shading, plant wind, weather detail and bloom. Depth of
field, camera motion blur and vignette are off by default. Wind uses the same
terrain and shadow vertices.

The declared 4 ms budget at 1920×1080 is a design target, not a measured GPU result.
The project report compares Medium and High with rc1 using bracketing runs on the
same software renderer; it includes sample counts and host-load variation.

## Public Nightly limits

Local air is an approximation from visible emissive terrain and screen depth.
Offscreen sources and emitters covered by opaque or transparent geometry are
outside its source field. Depth checks reduce visible wall leakage but cannot
recover hidden geometry, provide local-light shadow maps or simulate arbitrary
bounce light. Sources are selected from a bounded field, with a finite support
radius and two/three contributing source blocks. Existing block-light levels
continue to supply the engine's surface falloff and wall occlusion.

The native moon phase texture remains. Only the added sky aureole estimates phase
from those visible pixels: API 0.1 exposes no phase value for directional surface
light or the water's analytic moon path. Those remain approximations.

The ordinary Nightly has no pack entity material stage. Entities retain engine
lighting, and native culling can remove offscreen entity shadow casters.
Screen-space water reflections lose terrain outside the screen; misses use the
same original sky and cloud field. Waves change normals and refraction, not the
water mesh. Water depth and the bed pattern are approximations.

The world frame stores bounded gamma colour. Highlight shoulders preserve
gradation but cannot supply a true HDR world buffer; transparent surfaces still
blend in native gamma space. Contact shading sees only visible solid terrain.
Clouds use bounded procedural sampling; snow and auroras use the camera biome.
There is no temporal accumulation or object motion blur. Native precipitation
ordering and some additional post fog remain engine limitations.

The [project README](https://github.com/lkjsxc/sunsunshader) contains current native
pictures, exact compatibility pins, profile costs, review evidence and build
instructions. The separate API 0.2 development variant has not been promoted to
this public Nightly release.

All shader code is original and licensed under Apache-2.0. Published mathematical
methods are credited in source comments; no other shader pack is used as source.
