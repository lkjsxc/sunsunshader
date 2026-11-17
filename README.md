# Sunsun Shader

A native Horizon shader pack with warm daylight, cool shade, soft clouds and clear water.

![Coastal daylight](docs/media/noon.jpg)
![Sunset over water](docs/media/sunset.jpg)
![Shallow water](docs/media/shore.jpg)
![Moonlit coast](docs/media/night.jpg)
![Torch-lit cave](docs/media/cave.jpg)

## Install

Tested in **Horizon Nightly 2026-11-13 · 9f42064**, the public launcher Nightly,
for Minecraft Java Edition 26.3. The release uses that game's shader API **0.1**.

Download [sunsunshader-0.1.1.hshader](https://github.com/lkjsxc/sunsunshader/releases/download/v0.1.1/sunsunshader-0.1.1.hshader),
put it in your game directory's `shaderpacks/` folder, then select **Sunsun Shader**
under Options → Video Settings → Shaders → Shader Packs. Remove the installed 0.1.0
copy and keep one Sunsun Shader file. No experimental environment switch is required.

Use `sunsunshader-0.1.1.hshader` for Nightly 2026-11-13; the separate
`sunsunshader-0.1.1-main.hshader` built from this repository is for development
builds using shader API 0.2. The formats differ because those game versions do not
accept the same shader API. Version 0.1.0 is replaced by 0.1.1.

Folder installation also works: copy `pack/` as `shaderpacks/sunsunshader/`.

## Profiles and options

**Medium is the default.** Profiles change cloud, shadow-filter, reflection,
light-shaft and edge-filter work.

| Profile | Cloud cells / storm steps | Shadow filter | Water terrain reflection |
|---|---:|---:|---|
| Low | 6 | 4 taps | Sky only |
| Medium | 12 | 8 taps | Screen space |
| High | 18 | 12 taps | Longer screen search |
| Ultra | 28 | 16 taps | Longest screen search |

Clear clouds integrate up to the listed number of cells; storm clouds use the
listed march steps. The fields blend as weather changes. High and Ultra also
reflect the cloud volume. The shadow map is 1536×1536 in every profile.

| Option | Effect |
|---|---|
| Exposure | Overall brightness with mild, slow adaptation. |
| Air density | Distance haze and low fog. |
| Clouds | Low cloud volumes, high cirrus and cloud shade. |
| Shadows | Filtered sun and moon shadows. |
| Terrain reflections | Visible terrain in water; sky reflection remains. |
| Weather detail | Wet surfaces, a light cold-biome snow coat, rainbows and auroras. |
| Bloom | Wide glow around bright light. |
| Depth of field | Focus at the screen centre; off by default. |
| Camera motion blur | Blur from camera movement; off by default. |
| Vignette | Slightly dim corners; off by default. |

The manifest's **4 ms at 1920×1080** budget is a Medium design target, not a
measured result. No hardware GPU timing is available.

## Current limits

The public Nightly has no custom entity shading or material ray queries. Mobs,
items, particles and the hand retain engine lighting. Its normal world frame
cannot carry HDR highlight energy. Bright pack colours keep their hue but have
dimmer cores and less bloom than the development variant. The native moon has
a slightly stronger blue halo. Native
transparent draws blend in the game's gamma space. Some native draws can
receive additional post fog.

The moon retains Horizon's phase texture. Custom lunar orbits, eclipses and
lightning inside clouds are absent. Screen-space reflections cannot see
offscreen terrain; Low and Medium reflect the atmosphere without cloud volumes.
Water waves change normals and refraction, not the mesh; caustics are a
procedural bed pattern. Snow and auroras use the camera biome. Wet ground has
sky and sun gloss. Temporal accumulation and object motion blur are absent.
Clear clouds remain smooth; heavy rain can retain shallow-angle layering.

Screenshots show the released 0.1.1 archive in the published Nightly, rendered
with Mesa Lavapipe at 960×540 and ten chunks. They show appearance, not GPU
performance. The earlier promo video was recorded in a development build and
is not part of this release.

## Build and check

Python 3.11+, Git and stable Rust are required.

```sh
python3 tools/release.py check --self-test
python3 tools/release.py build
```

Both commands package and validate the Nightly and development variants, using
their separately pinned, unmodified Horizon validators. Files are written to
`dist/`. Use `--target nightly` or `--target main` to build one.

The Nightly is pinned by the permanent tag
`nightly-source/2026-11-13-9f42064` in
[compatibility/horizon.json](compatibility/horizon.json). Its launcher installation
name is `nightly-2026-11-13-9f42064`.

CI runs the same packed-file checks and negative refusal tests. The gate also
checks the ordinary game's admission rules: this Nightly's parser accepts some
experimental features its normal game does not draw. Each checked file gets a
SHA-256 sidecar and a validation receipt.

When a new public Nightly ships:

1. Verify its published release, permanent source tag, player-visible version and binary.
2. Update the Nightly pin and review the pinned game's admission rules and shader API.
   Adapt or promote the matching pack variant and update both READMEs.
3. Run `python3 tools/release.py check --self-test`, then select the resulting
   archive in that unmodified Nightly and compare noon, sunset, night, shore,
   forest shade and cave with the current pictures.
4. Capture the final archive, commit and push, then publish through the gated command:

```sh
python3 tools/release.py release dist/sunsunshader-0.1.1.hshader --notes release-notes.md
```

Use the new pack version's filename when making a later release. Publication
rechecks the exact file and refuses stale bytes, uncommitted changes or a source
commit that has not been pushed. See [tools/README.md](tools/README.md) for source
cache controls and the development variant.

All shader code is original and licensed under Apache-2.0. Published methods
are credited in source comments.
