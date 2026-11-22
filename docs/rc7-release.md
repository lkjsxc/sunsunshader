# Sunsun Shader 0.2.0-rc7

Sunsun rc7 is for Horizon Nightly 2026-11-19 (5ef7734) with shader API 0.2. Place the archive in the game's `shaderpacks/` folder and select Sunsun Shader. Medium is the default profile. **Light in the air**, depth of field, camera motion blur and vignette are off by default.

- The post-processing graph is folded from 12 post entries to 9, and from 8 draw passes to 5. Compose combines bloom, camera blur and optional focus. Display applies edge resolve and filmic output. With Light in the air off, Haze clear and Resolve do no work.
- Edge resolve and focus remove single-pixel flecks that rc6 left in the checked scenes.
- Static checks cover camera motion blur’s fade at the edge of the previous view.

The folded graph was compared with the unfolded graph carrying the same fixes in seven software-rendered scenes at 1920×1080. Mean differences were at most 0.017 codes, and peaks were 1–3 codes out of 255.

## Measured cost

These measurements used a Radeon 780M (RADV, Mesa 26.3.1), Horizon 5ef7734, 1920×1080 offscreen SDR and two frozen scenes. The arm figures are medians of the per-run p50 GPU spans across six runs. Added cost is the median paired difference. Runs alternated with Horizon without a shader pack.

| Profile | Scene | No pack | Sunsun | Added |
| --- | --- | ---: | ---: | ---: |
| Medium | Night lantern | 0.72 ms | 13.29 ms | +12.57 ms |
| Medium | Rain | 1.18 ms | 16.10 ms | +14.92 ms |
| Low | Night lantern | 0.72 ms | 8.87 ms | +8.15 ms |
| Low | Rain | 1.18 ms | 11.58 ms | +10.41 ms |

On Medium in the same setup, turning **Clouds** off saved 4.7 ms in the night-lantern scene and 5.9 ms in rain. The manifest targets 4 ms at 1920×1080. The timed archive is the folded build that rc7 was promoted from. With camera motion blur off, rc7's default path is statically identical to it. Pass instrumentation was on in both arms and adds more timer work with the pack active. The figures describe offscreen GPU spans.

The release archive passed the pinned Nightly validator, ordinary-game admission, negative admission and post-continuity checks. The exact archive also rendered on the same Radeon.

Archive SHA-256 `e9ad02f6c8f827e72fa8317a08d2cba93dda63db91763c8935d99ffe8ac475fe`.
