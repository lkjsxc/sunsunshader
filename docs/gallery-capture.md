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
`python3 tools/release.py build`. Supply the emitted
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
the CachyOS run. Set a cleanup deadline in your timezone. Use a new output
directory for each run.

```sh
systemd-run --user --wait --collect --pipe --unit=sunsun-gallery \
  --property=KillMode=control-group --property=TimeoutStopSec=10 \
  --property=Nice=19 --property=CPUWeight=10 --working-directory="$PWD" \
  python3 tools/gallery-capture.py --pack "$RC5_PACK" --bin "$HORIZON_BIN" \
    --resources "$HORIZON_RESOURCES" --output .build/gallery-radeon \
    --backend gamescope --idle-guard "$CONTINUOUS_IDLE_GUARD" --deadline "$GPU_HANDBACK"
```

Pass the continuous watch build of `edge-input-idle` via `--idle-guard` when
staging the runner. It confirms 15 seconds of inactivity on the owner Wayland
seat (`wayland-1`) before starting headless Gamescope. One connection watches
for resumed input until a compositor roundtrip after the renderer exits. A
refusal leaves the suite incomplete and records the reason. Start a new suite
in a fresh directory once the seat is idle. The supervisor reserves 20 seconds
for cleanup before the deadline, and the systemd user service limits
termination to its own processes.

Add `--timing-scene night-lantern` for one optional sample in an active full-size
Gamescope capture. The flag is repeatable. The timing path resets pass history,
warms up for ten seconds, records `bench 8 raw`, and disables pass timing.
`--timing-warmup` and `--timing-seconds` change those durations. `--profile`
selects Low, Medium or High; Medium remains the catalogue default. A single
sample is diagnostic only. Use the paired procedure below for comparisons.

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
from `(0, 70, 0)` and expects the seed-42 result at X 272, Z 112. The five
fixed poses were selected during a 42-frame native scouting pass. The
atrium camera is inside the bounds of the generated `atrium_1` piece. Each
replay checks the subject block, including both lit bulbs in the copper scene.

## Private native timing comparisons

`gallery_timing.py` schedules the existing gallery capture command and reduces
its records locally. It does not implement another game launcher. It supports
the exact `5ef7734` native benchmark format; a newer Nightly needs a source
audit and format update. These measurements are native renderer diagnostics,
not presented FPS or a comparison with another client.

The gallery launches Horizon with **`--offscreen`**. There is no swapchain
presentation in this path; Horizon limits outstanding GPU work to two frames.
The recorded `present_mode` is its configuration field, not an active display
mode. The report records this rendering path explicitly. It cannot reproduce
or explain presentation/synchronization cost in the separate presented-client
comparison merely by comparing elapsed-frame values.

Prepare **two exact archives**, each with its clean-source Nightly `.check.json`
receipt and a pin produced by `gallery-pin.py` above. The pins must identify
the same signed Horizon distribution and binaries. Both archives must retain
the same option defaults and timed stage labels. Choose the same named quality
preset for both. The harness writes every effective pack option explicitly.
Changed stage topology or defaults require a separately designed comparison;
the reducer does not invent equivalent passes or fill missing values with zero.

First run the read-only preflight on the intended machine. It validates pack
and binary identities, hashes the prepared resource files, checks the selected
scenes and prints the interleaving schedule without opening a display:

```sh
python3 tools/gallery_timing.py plan \
  --pack-a "$BASE_PACK" --pin-a "$BASE_PIN" \
  --pack-b "$CANDIDATE_PACK" --pin-b "$CANDIDATE_PIN" \
  --bin "$HORIZON_BIN" --resources "$HORIZON_RESOURCES" \
  --scene night-lantern --scene sunset-water --profile Medium \
  --rounds 3 --warmup 10 --seconds 8
```

The values named above are paths to the operator's prepared inputs, not a
request to download another client or access an account. A and B must have
different archive hashes. Never borrow a running game, an owner's save,
account state, or another worker's display.

**Run only in the next confirmed idle hardware interval**, after the active
comparison worker has finished and the owner has handed back the GPU. Keep the
physical seat guard and an explicit handback deadline. Do not stop a worker or
extend a deadline to complete a partial suite. Start a fresh directory:

```sh
systemd-run --user --wait --collect --pipe --unit=sunsun-native-timing \
  --property=KillMode=control-group --property=TimeoutStopSec=20 \
  --property=Nice=19 --property=CPUWeight=10 --working-directory="$PWD" \
  python3 tools/gallery_timing.py run \
    --pack-a "$BASE_PACK" --pin-a "$BASE_PIN" \
    --pack-b "$CANDIDATE_PACK" --pin-b "$CANDIDATE_PIN" \
    --bin "$HORIZON_BIN" --resources "$HORIZON_RESOURCES" \
    --scene night-lantern --scene sunset-water --profile Medium \
    --rounds 3 --warmup 10 --seconds 8 \
    --deadline "$GPU_HANDBACK" --output .build/native-timing-pair
```

Each round is a balanced four-run block, alternating **ABBA, BAAB, ABBA**.
Three rounds therefore start twelve independent gallery clients, six per
archive. Each client visits the same scenes in the same order. The warmup and
sample windows alone take 7.2 minutes for two scenes; private resource copies,
startup, world loading, exact setup ticks, admission images and cleanup take
additional time. Reserve enough idle time for the whole schedule. A stopped
suite remains incomplete and cannot be reduced by retaining only its successful
runs. The systemd control group is the cleanup backstop for descendants if the
supervisor itself is interrupted.

### What is held constant and checked

Timing captures keep the new world frozen from startup using Horizon's
`HORIZON_STILL` behavior. Scene preparation advances exactly 40 ticks before
setup, then 40 or 120 ticks for clear/rain settling. Loading waits do not
advance the world. This keeps both daylight time and the shader's authoritative
`game_time` phase reproducible. The before/after records include that clock;
`state.ticks` would be the client clock and is not a substitute.

Before warmup and after sampling, the native screenshot-sequence reply must
name the exact installed pack. The pack bytes and effective option file are
checked as well. The admission screenshot resets native kept history, so
warmup is **after** the first admission. The sample then uses the normal frozen
world phase. These first-frame admission images are not the warmed benchmark's
visual comparison. Use separately reviewed matched gallery captures to judge a
rendering change.

Pass timing is explicitly turned off across a two-client-tick wait,
then turned on before warmup. `bench` alone resets elapsed-frame statistics
without clearing the pass windows. There are no screenshots during the sample.
The native FPS option is set to 260, its unlimited-slider value, and VSync is
disabled. Reported present-mode configuration and other renderer settings are retained; neither
setting proves unlimited presentation throughput.
The inactivity option is explicitly `minimized`: the native default `afk`
would otherwise apply 30/10-FPS limits after 60/600 seconds without input.
The observed option is checked at both boundaries of every sample.

The reducer requires matching scene setup, camera, seed, daylight and weather,
world animation clock, preset and options, resource bytes, tool versions,
client binaries, dimensions, renderer/driver/backend/present mode, machine,
resident terrain and stable power/governor observations. It also checks the
native pack activation on both sides of every sample, all expected pack pass
names, the required renderer pass names and identical complete observed pass
sets across runs. Missing metadata, raw arrays, pass names, incomplete cleanup,
changed raw files or reordered runs cause a diagnostic failure.

The pinned deterministic screenshot-sequence rejects LOD. Consequently timing
currently accepts **near scenes only**; `distant-lod` remains available for
ordinary gallery images but fails timing preflight. A native activation query
that supports LOD is needed before expanding this timing contract.

Power state, CPU governor, load averages and available temperatures are read
before and after each sample. They provide context, not a continuous GPU power
trace, thermal correction, or proof that no other workload ran. Keep the host
idle, use stable power and inspect those records before interpreting differences.

### Stock Horizon as arm A

A suite may compare one pack against **stock Horizon**: the same signed client
with no shader pack. Only arm A can be stock, and B must be a pinned pack.
Stock against stock, a stock B and option isolation with a stock arm are all
refused. Pin stock from the same signed Nightly files that B's pin used, then
omit `--pack-a`:

```sh
python3 tools/gallery-pin.py --stock --nightly-archive "$ARCHIVE" \
  --sums "$SUMS" --signature "$SIG" --output "$STOCK_PIN"
python3 tools/gallery_timing.py plan --pin-a "$STOCK_PIN" \
  --pack-b "$CANDIDATE_PACK" --pin-b "$CANDIDATE_PIN" \
  --bin "$HORIZON_BIN" --resources "$HORIZON_RESOURCES" \
  --scene night-lantern --scene rain --profile Low --rounds 3
```

The pin is exactly `{"schema": 1, "arm": "stock", "horizon": …, "pack": null}`,
and its `horizon` object must equal B's. The stock capture writes the same
`options.txt` and `horizon-graphics.txt` lines as B except an empty
`pickedShaderPack:`, and it leaves `shaderpacks/` empty with no
`.horizon-options`. `inputs.json` declares that staging. `cleanup.json` records
the `shaderpacks/` listing at client launch and again after quit, and both
listings must be empty. Every screenshot-sequence reply must name exactly
`{"kind": "none", "name": null}`. The installed pack, its hash and the pack
options are recorded as `null` and checked as `null`. The stock benchmark must
report a `World` renderer row, no `shader_passes`, and none of the pack-only
rows (`Native shader pack shadow`, `Native shader pack translucent shadow`,
`World after copy`, `Flatten`, `Flatten phase 2`). The first stock run fixes the
exact stock label set, and every later stock run must repeat it. Stock LOD
scenes are refused because no route proves that no pack is active with LOD.

Only the pack identity, preset, pack options and expected pass names are left
out of the cross-arm condition key. B's preset contract is fixed in
`suite.json`. Within each arm the full key and the pass label set must repeat.
Paired Δ covers only GPU-span p50, elapsed-frame p50 and p95, and CPU-work
p50. Renderer and pack rows are reported per arm and never differenced. Pass
timers are on in both arms and B times more passes, so Δ is biased upward.

Before the first stock-relative suite, run `plan` on the measurement host and
one stock capture as a preflight. The capture records the stock label set and
confirms the no-pack admission reply. Keep it as a preflight, not as a
measurement.

### Reduction and interpretation

Successful runs produce `.build/native-timing-pair/reduced/timing.md` and
`summary.json`. To repeat the deterministic reduction into a new directory:

```sh
python3 tools/gallery_timing.py reduce .build/native-timing-pair \
  --output .build/native-timing-pair/reduced-again
```

All table values are milliseconds. An arm's estimate is the median of its
independent run estimates, with the observed minimum and maximum. Each paired
delta is B minus A within one four-run block, using each arm's two-run mean;
the table gives the median and observed range of those block deltas. Frames
are not treated as independent repeat experiments. Ranges are **not confidence
intervals**, and an apparent improvement is not a causal finding by itself.

- Elapsed-frame p50/p95, CPU-work p50 and GPU-span p50 are recomputed from the preserved
  native arrays with the pinned nearest-rank definition. GPU timestamp arrays
  arrive asynchronously and can have a different length from elapsed frames;
  the arrays are never joined by index.
  The native GPU span starts after earlier upload/preparation commands and ends
  before later presentation work; it is not complete GPU service time.
- Renderer and pack rows are **end-of-run rolling medians over up to 15 recent
  timestamp observations per pass**. They are not medians of the entire
  eight-second sample. This Nightly supplies no raw per-pass arrays, sample
  counts or ages in `bench raw`. Repeat ranges describe those endpoint estimates,
  not a within-run pass distribution. Do not add the pass medians to reconstruct
  a whole-frame time.
- Timestamp instrumentation is enabled. Elapsed-frame intervals include waits
  and are not physical display presentation events. No FPS column is inferred
  from them. A presented-FPS claim needs a separate presentation measurement.

The two pass namespaces describe native timer ownership, not causal ownership
of cost. Native solid/translucent shadow passes appear under renderer timers;
the pack's vertex and material work shares world draws. Instrumented sky can
move into its own timed pass. Preserve these labels and compare controlled
pack changes before assigning cost. Subtracting independently sampled medians
cannot identify present/sync waits or explain a Java-versus-Horizon gap.
Horizon's existing local profiler can retain sparse per-pass frames for a
separate marked diagnostic, but those streams also lack a common render/submit/
present ID. This reducer deliberately admits only the checked `bench raw` format.

The complete native reply stays in each scene's `.timing.json`, including all
raw frame values and native fields the reducer does not use. Nothing is trimmed
or silently discarded. `summary.json` links the retained raw records and counts
and records the reducer's own source hash.
Failure writes `diagnostics.json` and no timing table. Keep the entire directory
private under `.build/`; do not publish raw records, private paths or a synthetic
fixture table as measured results.

The format and failure fixtures run without a renderer, account or network:

```sh
python3 -m unittest discover -s tools -p 'test_gallery_timing.py' -v
```

See [fixture provenance and native format sources](../tools/fixtures/README.md).
As of the source investigation for this tool, no complete matched `5ef7734`
Radeon 780M per-pass A/B set was available. The older raw flight samples and the
guard-stopped gallery attempt do not establish an improvement.

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
  --scene rain-coast --scene trial-atrium --scene trial-stair-hall --scene trial-spawner \
  --scene trial-vault --scene trial-copper
```

The asset command requires Pillow. It resizes the thumbnails and compresses
the native captures without color adjustments.
