# Sunsun Shader

Sunsun Shader is a native shader pack for Horizon, the Minecraft client written in Rust. It provides warm light in the air, dark unlit Overworld spaces, directional shadows, clear blue daylight, layered clouds, and reflective water.

Compatibility: [0.2.0-rc5](https://github.com/lkjsxc/sunsunshader/releases/tag/v0.2.0-rc5) is a release for Horizon Nightly 2026-11-19 · 5ef7734 (shader API 0.2), where older API 0.1 packs no longer load. Medium is the default profile. On Nightly 2026-11-18 · dd67b76, use [0.2.0-rc4](https://github.com/lkjsxc/sunsunshader/releases/tag/v0.2.0-rc4). On Horizon Nightly 2026-11-13 · 9f42064, use [0.2.0-rc2](https://github.com/lkjsxc/sunsunshader/releases/tag/v0.2.0-rc2).

## Install

Download [sunsunshader-0.2.0-rc5.hshader](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc5/sunsunshader-0.2.0-rc5.hshader) (SHA-256: 12dff8a0b1511eef04e0322e73659608d77ccf626b0d830f427b6c9b02f8abc3).

Put it in the game's shaderpacks/ folder and keep only one Sunsun archive there. Folder installation also works as shaderpacks/sunsunshader/.

Select Sunsun Shader under Options → Video Settings → Shaders → Shader Packs.

No experimental settings are needed. This candidate addresses haze flicker while walking and false halos near block edges.

## Screenshot gallery

[![Oak-fence lantern posts beside a village house at midnight](docs/media/rc5/night-lantern-thumb.jpg)](docs/media/rc5/night-lantern.jpg)

The rc5 gallery uses Medium on Horizon Nightly 2026-11-19 · 5ef7734.
The images were captured in 1920×1080 SDR with Mesa llvmpipe.
[More scenes](docs/gallery.md) · [Capture settings](docs/gallery-capture.md)

## Light, darkness and water

- **Light in the air:** visible torches, lanterns, lava and other emitting terrain
  seed a bounded source field. A finite camera-ray scattering integral uses real
  source positions, emission levels, light tint and scene depth. Night, low sun,
  rain, biome humidity and enclosed air increase the effect. Clear open noon
  receives none of this added local haze.
- **Dark unlit spaces:** the Overworld's ambient floor, decorative ore glow and
  cave exposure boost are removed. Fog cannot add unoccluded blue sky to a sealed
  room. The player's brightness multiplies existing faint light and preserves
  zero; native night vision and obscuring status effects remain supported.
- **Observed lunar air:** a broader aureole follows the visible native moon pixels
  and is composed behind clouds. A faint new-moon texture does not produce the
  new bright halo. Directional ground and analytic water moonlight still lack a
  native phase value; they are separate approximations.
- **Modest water refinement:** a narrower reflection cone where pixels resolve the
  water gives nearby cloud masses a little more shape. A third broad wave
  direction reduces the former two-direction rhythm without materially raising
  its unwarped slope strength. Distant filtering, the bounded visible normal,
  shore tracing, shallow refraction and highlight shoulders remain.

Existing directional sun/moon caster maps, coloured daytime shade, contact depth,
foliage transmission, anchored plant wind, eroded cumulus and the separate high
cloud layer are retained. Nether and End keep their separate dimensional
atmospheres.

## Profiles and measured cost

The **Light in the air** option is on by default. Medium and High use it; Low
retains optical bloom and skips the expensive added source/lunar sampling.
The common graph retains its haze resources on Low. The option can also be
turned off on Medium and High.

| Work | Low | Medium | High |
| --- | ---: | ---: | ---: |
| Shadow filter samples per map | 4 | 8 | 12 |
| Blocker-search depth samples | 0 | 8 | 12 |
| Contact-shading depth samples | 0 | 8 | 12 |
| Clear-cloud traversal cap | 8 cells | 14 cells | 22 cells |
| Density points per intersected cloud lobe | 2 | 3 | 5 |
| Reflected-cloud traversal cap | None | 10 cells | 16 cells |
| Screen-reflection depth steps | None | 12 + up to 4 refinement | 24 + up to 4 refinement |
| Visible local sources per air sample | Off | Up to 2 | Up to 3 |
| Source-path visibility depth checks, per source | Off | 2 | 4 |
| Daylight shaft samples | Off | Off | 10 |

All profiles retain a 1536×1536 shadow map with a 128-block half-distance.
Cloud traversal counts are bounds with geometric early exits; procedural density
work is arithmetic. One shadow comparison lookup performs native 2×2 PCF, with
opaque and transmitting maps sampled separately.

The local-light field accumulates visible observations in kept world buffers.
Quarter-resolution textures carry separate contributions for receiver lighting
and emitter halos. The earlier rc2/rc3 measurements below give historical
context for the look before that change.

<!-- LOOK5_COSTS_BEGIN -->
| Scene | Profile | rc1 before, ms | rc2, ms | rc1 after, ms | Change vs bracket | rc1 drift |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Night village | Medium | 217.63 | 177.66 | 180.37 | −20.46 ms / −10.33% | −17.12% |
| Night village | High | 209.87 | 215.69 | 210.35 | +5.58 ms / +2.65% | +0.23% |
| Torch/lava cave | Medium | 180.40 | 181.27 | 182.89 | −0.37 ms / −0.20% | +1.38% |
| Torch/lava cave | High | 147.12 | 155.49 | 169.75 | −2.54 ms / −1.60% | +15.38% |

The bracket reference is `sqrt(rc1_before × rc1_after)`. **Village Medium and
cave High are strongly affected by baseline drift**; their negative percentages
do not establish a speedup. Village High's observed increase is small relative
to overlapping repeat ranges, and cave Medium's difference is unresolved within
variation. Host variation prevents a precise causal overhead estimate.
<!-- LOOK5_COSTS_END -->

These are **960×540 Mesa software-renderer elapsed frame times**, using the same
published client and an eight-worker/CPU limit. Each row uses a separate
**rc1 → rc2 → rc1** bracket, with three 20-second native raw-frame samples per
block. Values are the median of the three repeat means. Both baseline sides,
their drift and repeat ranges are retained in the
[cost report](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/costs.md).
Bracketing reduces slow drift but does not remove shared-host or order effects.
This is a whole-pack comparison, not isolated haze cost or a hardware GPU claim.
The manifest's 4 ms at 1920×1080 remains a design target.

Other controls cover exposure, air density, clouds, shadows, terrain reflections,
wave strength, contact shading, plant wind, weather detail and bloom. Depth of
field, camera motion blur and vignette are off by default.

## Review evidence and limits

[Release and review files](https://github.com/lkjsxc/sunsunshader/releases/tag/v0.2.0-rc2)
include the installable archive, SHA-256, ordinary-game gate receipt,
[native paired sheet](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/contact.jpg),
[review](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/report.md)
and retained rounds. Each primary cell in the rc2 comparison is a native
960×540 capture from the pack bytes tested in that round. The rc5 gallery has
its own capture record. The promotional film is kept separate from this
release. [rc5 capture settings](docs/gallery-capture.md)

The local air field sees **visible emitting terrain only**. Offscreen and fully
covered sources, including emitters hidden by glass, are outside that effect.
The bounded world field and gather budget can omit a light when several sources compete. Screen-depth checks reduce visible obstruction
errors but cannot recover hidden geometry or provide full local-light transport.
Native block lighting still supplies its existing surface falloff and wall
occlusion.

Water is improved modestly and remains a weakness: distant cloud reflections
are soft, and a finite normal-wave spectrum still has a recognizable swell.
Offscreen shore is unavailable to screen reflections; misses use the same
procedural sky/cloud field. The native mirror has no exposed terrain mask and
contains a different sky, so it is not used. Waves affect normals/refraction,
not the water mesh.

Further public-Nightly limits remain:

- The current Horizon renderer can lose distant terrain casters at short
  full-detail distances. See [Horizon #19015](https://github.com/horizon-rust/horizon/pull/19015).
- Entity materials retain native lighting; offscreen entity casters can leave
  the native shadow map.
- The world buffer is bounded gamma colour. Highlight shoulders preserve
  gradation but cannot restore HDR radiance, and native transparent surfaces
  still blend in gamma space.
- The moon keeps its native phase texture. Only the added sky aureole estimates
  phase from visible pixels; surface and water lunar light remain phase-agnostic.
- Contact shade sees visible solid terrain. Motion uses spatial filtering without screen-space temporal accumulation or
  object-motion guides. Native precipitation
  ordering, and camera-biome snow/auroras, remain limitations.

## Build and check

Python 3.11+, Git and stable Rust are required.

```sh
python3 tools/release.py check --self-test
python3 tools/release.py build
```

Both commands validate the pinned Nightly and API 0.2 development variants
through unmodified Horizon validators. `--target nightly` builds this 0.2.0-rc5
release candidate. The separate `pack-main/` remains the 0.1.1 development visual baseline;
it is not the public Nightly download.

The ordinary-game admission check adds the restrictions of the pinned Nightly
renderer to its standalone parser and validator. CI includes negative refusal
tests and exact packed-file checks. The permanent source tag is
`nightly-source/2026-11-19-5ef7734`; distribution/source policy identities are
pinned in [compatibility/horizon.json](compatibility/horizon.json).

Save the reviewed rc5 notes to `.build/rc5-release-notes.md`. After validating
and reviewing the final bytes, publish with:

```sh
python3 tools/release.py release dist/sunsunshader-0.2.0-rc5.hshader --notes .build/rc5-release-notes.md --latest
```

Publication rechecks those bytes, rebuilds for byte identity, and refuses a dirty
checkout, an unpushed source commit or a mismatching tag. The GitHub Latest release is the candidate for the current public Horizon Nightly.
See [tools/README.md](tools/README.md) for the gate and pin
maintenance.

All shader code is original and Apache-2.0 licensed. Published mathematical
methods are credited in source comments; no other shader pack is used as source.

[Bliss Shaders](https://github.com/X0nk/Bliss-Shader) by Xonk was an early
visual reference for Sunsun. Bliss adapts Chocapic13's V9 shaders and carries
its own [license](https://github.com/X0nk/Bliss-Shader/blob/Stable/LICENSE.md).
