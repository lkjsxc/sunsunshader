# Sunsun Shader 0.1.1 — development variant

This variant uses Horizon shader API **0.2** and is checked against the development
source revision pinned in `compatibility/horizon.json` in the repository.

For the public **Nightly 2026-11-13 · 9f42064**, install `sunsunshader-0.1.1.hshader`
from the release. This `-main.hshader` variant is for API 0.2 development builds and
will be refused by that Nightly.

Build both variants with `python3 tools/release.py build` from the repository root.
Install only the file matching your game's shader API into `shaderpacks/`, then select
**Sunsun Shader** in Video Settings → Shaders → Shader Packs.

This variant keeps the linear HDR world frame, pack-owned frame fog, custom entity
lighting and experimental opt-in High/Ultra material ray reflections. Ray reflections
have no verified hardware image; screen-space reflection is the default. Horizon can
maintain a ray scene even when the query option is off. `HORIZON_RAY_TRACING=0` disables
that engine path.

Medium is the default. Depth of field, camera motion blur and vignette are off by default.
The 4 ms budget at 1920×1080 is a design target, not a hardware measurement. See the
[project README](https://github.com/lkjsxc/sunsunshader) for the other options and limits.

All shader code is original and licensed under Apache-2.0.
