# Sunsun Shader 0.2.0-rc2

**A pre-release for the ordinary public Horizon Nightly, with Medium as the default.**

This candidate concentrates on warm light suspended in air and dark
unlit Overworld spaces. The [five-scene comparison](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/contact.jpg)
places rc1 beside rc2 at the same lantern village, torch/lava cave, rainy dusk
forest, moonlit shore and clear-noon camera.

## What changed

- **Warm local air:** visible emitting terrain supplies real source positions,
  emission levels and light tint. Finite camera-ray scattering and depth-based
  visibility produce a soft aureole and pooled haze. Damp nights, rain, low sun
  and enclosed air increase it; clear open noon stays brilliant.
- **Darkness:** removed the Overworld ambient pedestal, decorative ore self-light
  and cave exposure boost. Closed rooms do not acquire blue sky fog. Brightness
  multiplies existing faint light while preserving black; native vision effects
  remain available.
- **Lunar air:** a broader aureole measures the native visible moon rather than
  inventing a direction-only glow. The added halo is suppressed for the tested
  new-moon texture and is composited behind clouds.
- **Water:** nearby reflected cloud masses are slightly more defined. A
  rebalanced third broad wave direction reduces the former two-direction rhythm,
  retaining the existing normal bounds, distant filtering, shore tracing,
  shallow refraction and highlight shoulders.

**Light in the air** is on by default for Medium/High. Medium gathers up to two
local sources with two visibility checks each; High allows three with four.
Low skips the expensive new air sampling and retains optical bloom, with the
small extra common-graph pass/target overhead.

## Install and compatibility

Use [sunsunshader-0.2.0-rc2.hshader](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/sunsunshader-0.2.0-rc2.hshader)
in the game's `shaderpacks/` folder, then select Sunsun Shader. Keep one Sunsun
archive installed.

Tested target: **Nightly 2026-11-13 · 9f42064**, ordinary shader API **0.1**,
without an experimental HDR switch. The gate checks the actual packed bytes
against the ordinary game's admission policy, in addition to shader validation.

Archive SHA-256:
`a9201e8247178e6110775c96cde7e6a5babe5d38b6d8f72450889f344634a8ac`.

## Measured software frame time

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

Each row is a separate rc1 → rc2 → rc1 bracket at 960×540, using the published
client and eight-worker/CPU limit. Each block has three 20-second native raw
samples; the value is the median repeat mean. Shared-host drift, both direct
ratios and all repeat ranges are in [costs.md](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/costs.md).
These are whole-pack software elapsed times, not hardware GPU results or an
isolated haze estimate. The 4 ms manifest budget remains a design target.

## Evidence and remaining limits

- [Native five-scene paired sheet](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/contact.jpg)
- [Water comparison](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/water-contact.jpg)
- [Review and limitations](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/report.md)
- [Retained visual rounds](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/rounds.md)
- [Runtime sampling audit](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/sampling-costs.md)
- [Review evidence bundle](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc2/look5-review.zip)

The air field sees visible emitting terrain, with finite support and a limited
source count. Offscreen sources and lights hidden by opaque or transparent
geometry are outside it. Screen-depth tests are an approximation; they do not
provide local shadow maps or hidden-world light transport.

Only the added sky aureole observes lunar phase. The engine exposes no
material-stage phase value, so directional ground and analytic water moonlight
remain phase-agnostic. Water still has soft distant cloud reflections and a
finite, recognizable swell spectrum. Its screen reflections cannot recover
offscreen shore.

Other native limits persist: bounded gamma world colour, native entity lighting
and caster culling, transparent blending and precipitation ordering. The review
describes their practical scope.

Previous releases remain available and unchanged. The promotional film is kept
separate and is not a release asset. All shader code is original and Apache-2.0
licensed.
