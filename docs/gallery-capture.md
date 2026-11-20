# Reproducing the rc5 gallery

The gallery uses Sunsun Shader 0.2.0-rc5 from source revision
`6dfcd7b6541acbafef75a6334fb0c4f23b8f4ed8` and Horizon Nightly
`nightly-2026-11-19-5ef7734`. Capture runs create a new local Overworld from
seed 42 with a temporary game directory, local control socket and private
display. The fixture consists of the seed and setup commands in the scene catalogue.
The rc5 run requires prepared Minecraft 26.3 resources.
[Scene catalogue](../tools/gallery-scenes.json)

Use the Linux x86-64 Nightly binaries and the public rc5 pack. The capture tool
checks both binaries and the pack against the checked input pin. The rc5 Linux
Nightly archive has SHA-256
`b682f4fca4fe521ad3df785b51b523a60789bf778267050794b9d678103a1956`.
Verify it against Horizon’s Ed25519 `SHA256SUMS.v2.sig` for the exact Nightly
version before installing it. Keep the versioned archive if you intend to
replay the gallery after the rolling Nightly changes.
[Horizon’s signed Nightly format](https://github.com/horizon-rust/horizon/blob/5ef7734fdd854add5efd6817178be3c988d8d050/docs/security.md#nightly-signatures)
[rc5 release](https://github.com/lkjsxc/sunsunshader/releases/tag/v0.2.0-rc5)
[rc5 input pin](../tools/gallery-inputs.json)

## Prepare a pin for another release

Build and validate the pack on the release source revision with
`python3 tools/release.py build --target nightly`. Supply the emitted
`.check.json` receipt and the matching Horizon Nightly distribution. The pin
builder requires OpenSSL 3 or newer and verifies the version-bound Ed25519
signature, signed archive checksum and the two capture binaries.

```sh
python3 tools/gallery-pin.py --pack "$PACK" --receipt "$PACK.check.json" \
  --nightly-archive "$NIGHTLY_ARCHIVE" --sums "$NIGHTLY_SUMS" \
  --signature "$NIGHTLY_V2_SIGNATURE" --output .build/gallery-inputs.json
```

Pass `--pin .build/gallery-inputs.json` to capture with those validated bytes.

## Capture

Python 3.11+, Gamescope, Vulkan and a Wayland input-idle guard are required for
the CachyOS run. Set the deadline to the agreed GPU handback in your timezone.
Use a new output directory for each run.

```sh
systemd-run --user --wait --collect --pipe --unit=sunsun-gallery \
  --property=KillMode=control-group --property=TimeoutStopSec=10 \
  --property=Nice=19 --property=CPUWeight=10 --working-directory="$PWD" \
  python3 tools/gallery-capture.py --pack "$RC5_PACK" --bin "$HORIZON_BIN" \
    --resources "$HORIZON_RESOURCES" --output .build/gallery-radeon \
    --backend gamescope --deadline "$GPU_HANDBACK"
```

The CachyOS guard checks the owner Wayland seat (`wayland-1`) before spawning
an independent headless Gamescope display. It rechecks for input inactivity
throughout the run. A refusal ends the run, and the supervisor reserves 20
seconds for cleanup before the deadline. The systemd user service limits
termination to processes started by this command.

Add `--timing-scene night-lantern` for one optional sample in an active full-size
Gamescope capture. It enables native GPU pass timing, warms up for three
seconds, records `bench 8 raw` and disables pass timing. The timing receipt
records whether the native result supplied both pass maps.

For a software rehearsal, use `--backend software --software-icd "$LAVAPIPE_ICD"`.
That path uses a private Xvfb display and Mesa lavapipe with four low-priority
workers. The review sheet shows the renderer reported by Horizon. Use
`--scene rain` for a single view, `--scout` for 480×270 or `--catalogue PATH`
for a generated scouting matrix. Full captures are 1920×1080 SDR. The rc5
manifest uses BT.709 frame primaries and the pinned Nightly rejects the native
BT.2020 pack frame contract. HDR screenshots require a separately verified
native HDR pipeline and display.

The near scenes use Horizon’s native fixed-clock screenshot sequence. The
distant scene waits for resident far terrain and uses Horizon’s native still
screenshot at the same frozen world time and camera pose on each replay.
Terrain refinement follows the renderer’s wall clock.

The trial-chamber run checks `/locate structure minecraft:trial_chambers`
from `(0, 70, 0)` and expects the seed-42 result at X 272, Z 112. The four
fixed poses were selected during a 40-frame native scouting pass. Each replay
checks the generated subject block. The copper scene checks both lit bulbs.

## Release readiness

- Check `complete.json` and the per-frame receipts for the baseline and chosen trial-chamber scenes.
  Verify the pack hash, renderer, dimensions, scene state and LOD residency.
- Generate the private contact sheet and have Claude review the actual frames.
  Supply another completed run after the baseline directory to use reviewed
  reshoots from the same renderer and inputs.
- Use Neon’s caption draft after the selection and have Claude check the
  captions against the selected images, capture receipts and release links.
- Compress only the reviewed selections. Reuse the 480×270 thumbnails in the
  README and release notes, and link them to the full-resolution JPEGs.
- Check the public assets and links. Keep the capture PNGs, temporary saves,
  renderer logs and private review notes in `.build/`.

```sh
python3 tools/gallery-assets.py .build/gallery-radeon --sheet .build/review.jpg
python3 tools/gallery-assets.py .build/gallery-radeon --gallery .build/gallery-release-assets \
  --archive .build/sunsunshader-rc5-gallery.zip \
  --scene night-lantern --scene sunset-water --scene cave --scene distant-lod \
  --scene rain-coast --scene trial-stair-hall --scene trial-spawner \
  --scene trial-vault --scene trial-copper
```

The asset command requires Pillow. It resizes the thumbnails and compresses
the native captures without color adjustments.
