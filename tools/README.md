# Compatibility and release tools

Python 3.11+, Git, and stable Rust are required. Publishing also requires an already authenticated `gh`.

```sh
python3 tools/release.py check --self-test
python3 tools/release.py build
python3 tools/release.py check dist/sunsunshader-0.2.0-rc1.hshader --target nightly
python3 tools/release.py release dist/sunsunshader-0.2.0-rc1.hshader --notes release-notes.md --prerelease
```

`check` without a file and `build` both build and check the Nightly and development archives. Select one with
`--target nightly` or `--target main`. Outputs go to `dist/` unless `--out-dir` is given. The Nightly file has
no suffix; the development file ends in `-main.hshader`. CI runs the same command.

The tool fetches the exact source in `compatibility/horizon.json`, verifies the tag and commit, requires a clean
checkout, and builds Horizon's own `horizon-shader` with its lockfile. It checks the packed file through that
parser and shader validator. The ordinary Nightly game has additional admission rules: its parser accepts
experimental API 0.2, but its normal game only draws API 0.1. The gate enforces the ordinary game contract as
well. Negative tests exercise an unknown field in a ZIP and an API 0.2 archive which the parser accepts but
the normal game refuses. No experimental environment flag qualifies as release compatibility.

The admission source digest in the pin records the audited game rule. A pin update requires reviewing that
source, its API and renderer changes, adapting the pack, running this gate, and repeating the scene comparisons and motion captures
using the exact final archive. Update the player-visible game version and screenshots before releasing.
Never replace the Nightly pin with an arbitrary development commit. The development target is separate.

To reuse existing clean checkouts, set `SUNSUN_NIGHTLY_SOURCE` and/or `SUNSUN_MAIN_SOURCE` to their absolute
paths. They still undergo the same revision, cleanliness and source-policy checks and rebuild the validator;
there is no override for an arbitrary executable. Cached default checkouts are under `.build/`. After moving a
pin, remove only the corresponding default checkout or point the environment variable at a fresh checkout.
At most twelve Cargo jobs are used; `CARGO_BUILD_JOBS` can lower that.

Each checked file has a `.check.json` receipt and a `.sha256` sidecar. The receipt names the exact file hash,
Nightly tag, source revision, validator hash, complete validator result and ordinary game admission result.

The release command snapshots the supplied archive, revalidates those bytes with the Nightly gate, rebuilds
the current pack and requires byte identity. It then requires clean committed `main`, the same commit on
`origin/main`, and any existing version tag to name that commit. Only after these checks does it create the
GitHub release with the checked Nightly archive, checksum and receipt. `--dry-run` performs the same checks
without a GitHub write. The development archive is not published by this command.

GitHub Latest must be the build that works on the current public Horizon Nightly.
Use `--latest` to publish that build as a normal release, including an `-rc` version.
The tool continues to default hyphenated versions to pre-releases, and
`--prerelease` explicitly selects a pre-release. Both modes use the same checks
for compatibility, source identity, cleanliness and the pushed commit.
