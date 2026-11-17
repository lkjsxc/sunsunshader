# Sunsun Shader 0.2.0-rc1

**This is a pre-release for the ordinary public Horizon Nightly. Medium is the default.**

The picture has been revised against nineteen matched views of the same review world, with 0.1.1 on the left and this candidate on the right. Four rounds of visible criticism and shader changes were followed by a complete confirmation capture.

## What changed

- **Directional light and shadows:** real sun/moon caster maps now produce useful contrast on terrain, houses, cutout foliage and available native entities. Blocker separation softens shadow edges. Independent coloured sky fill keeps shade readable, and forest leaves cast broken light.
- **Clearer light and colour:** a deeper blue sky and blue distance replace much of the daytime grey veil. Warm direct light contrasts with cooler shade. Source and final highlight shoulders retain gradation and lava colour within the Nightly's bounded world buffer.
- **Reflective water:** Medium/High reflect the same procedural sky and cloud field, plus visible shore through screen-space tracing. Fresnel, filtered waves at several scales, a broad solar path, real bed refraction, depth absorption and a shallow-edge transition give water more structure. A visible-normal filter removes the most conspicuous pale reflection web.
- **Clouds and weather:** eroded cumulus varies in width and vertical development, with shallow fragments, taller forms, shaded bases and a directional low-sun rim. A separate high layer remains. Rain has a subdued atmosphere and relit streaks without the earlier hanging dark fringe in the reviewed scenes.
- **Local depth and night:** contact shade, foliage transmission and gentle anchored plant wind add detail. Moonlight models the ground; varied stars, a soft band, native moon halo, warm light sources and restrained bloom support the night. High adds a quiet air-scattering march.

## Install and compatibility

Use [sunsunshader-0.2.0-rc1.hshader](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc1/sunsunshader-0.2.0-rc1.hshader) in the game's `shaderpacks/` folder, then select Sunsun Shader. Keep one Sunsun archive installed.

Tested against **Nightly 2026-11-13 · 9f42064**, using shader API **0.1**, without an experimental HDR switch. The release gate checks the actual packed bytes and the ordinary game's admission policy; a standalone parser pass alone is insufficient. The attached checksum and gate receipt identify the download.

Archive SHA-256: `7b1846386d9b502404bd2ba9725b867839dd64071de62c3c9d03cc168819caf1`.

## Profiles and measured software cost

All profiles retain real shadow maps. Low reduces filtering and detail; High extends cloud/reflection sampling and adds the shaft march.

The initial sequential run recorded the following median repeat means. Each ratio
uses the matching scene's **0.1.1 Medium** baseline: 168.9 ms at noon, 259.2 ms over
water and 371.1 ms in the forest.

| Profile | Noon | Grazing water | Forest, 08:00 | Three-scene geometric mean |
| --- | ---: | ---: | ---: | ---: |
| Low | 261.1 ms · 1.55× | 263.3 ms · 1.02× | 517.0 ms · 1.39× | 1.30× |
| **Medium** | **307.5 ms · 1.82×** | **458.5 ms · 1.77×** | **616.9 ms · 1.66×** | **1.75×** |
| High | 292.0 ms · 1.73× | 376.1 ms · 1.45× | 424.7 ms · 1.14× | 1.42× |

Medium took **66–82% more frame time** in these three sequential comparisons
(74.9% by their geometric mean). This is an observed run result on a shared host.
High measured faster than Medium in this sequence despite its greater sample
budget; changing machine load and different sampling periods make that ordering
unsuitable for choosing a profile. The [cost review](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc1/costs.md)
retains repeat spread, feature ablations, equal-duration Medium/High/Medium
controls and a fresh old/new forest comparison.

Measurements use the same published client, 960×540 scene and eight-worker limit as 0.1.1 Medium. They are software-renderer comparisons, not hardware GPU performance claims. The manifest's 4 ms budget remains a design target. The report includes repeat spread, feature ablations and sample/tap bounds.

## Evidence and remaining weaknesses

- [Full nineteen-scene comparison, native 960 px cells](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc1/contact.jpg)
- [Appearance, limits, motion and cost report](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc1/report.md)
- [Retained review rounds](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc1/rounds.md)
- [Public Nightly capabilities](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc1/capabilities.md)
- [Review evidence bundle](https://github.com/lkjsxc/sunsunshader/releases/download/v0.2.0-rc1/look4-review.zip)

README photographs are renewed from native captures of these exact pack bytes. The short validation clips use controlled native world ticks and a camera path at walking height; their playback rate is not real-time software performance.

**Water remains the weakest visual element:** cloud reflections are deliberately soft, and long swells retain a regular rhythm at grazing angles. Night and End changes are more modest than the daylight gains; outward window glow and High air are restrained.

Public-Nightly limits remain: offscreen shore is unavailable to SSR; native entity materials retain their lighting; offscreen entity casters can be culled; the world buffer remains bounded gamma colour; and the moon retains its square phase texture. Native precipitation writes no depth before post clouds, so the rain relighting mitigates an ordering limitation rather than repairing it. The overhang exposure supplement is a shallow opening, not proof of every deep cave mouth.

Version 0.1.1 remains available and unchanged. The promotional film was not rendered or uploaded in this run. All shader code is original and Apache-2.0 licensed.
