#!/usr/bin/env python3
"""Check post continuity against the pinned Horizon shader API."""

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tomllib

import release


HORIZON_REVISION = "5ef7734fdd854add5efd6817178be3c988d8d050"
NAGA_VERSION = "30.0.1"
SOURCE = Path(__file__).with_name("post_ir")
POLICY = Path(__file__).with_name("post_continuity.json")
BUILD = release.ROOT / ".build/post-ir"


@dataclass(frozen=True)
class Checker:
    binary: Path
    dependencies: dict
    sha256: str


def package_identity(package):
    return tuple(package.get(key) for key in ("name", "version", "source", "checksum"))


def build():
    pin = release.nightly_pin()
    if pin["revision"] != HORIZON_REVISION:
        raise release.Refused("Recheck the continuity policy for the changed Horizon pin")
    source = release.verified_source(pin)
    api = source / "crates/horizon-shader-api/Cargo.toml"
    naga_manifest = source / "third_party/naga/Cargo.toml"
    seed = (source / "Cargo.lock").read_bytes()
    pinned = tomllib.loads(seed.decode())["package"]
    versions = {dep: next(p["version"] for p in pinned if p["name"] == dep)
                for dep in ("serde", "serde_json", "sha2")}
    BUILD.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(BUILD / "target")
    env["CARGO_BUILD_JOBS"] = str(min(12, max(1, int(env.get("CARGO_BUILD_JOBS", "12")))))
    env["CARGO_INCREMENTAL"] = "0"
    # The harness owns its manifest, lock and build outputs. The path crate stays read-only.
    with (BUILD / ".lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest = BUILD / "Cargo.toml"
        content = f"""[package]
name = "post-ir"
version = "0.0.0"
edition = "2024"

[[bin]]
name = "post-ir"
path = {json.dumps(str(SOURCE / "main.rs"))}

[dependencies]
horizon-shader-api = {{ path = {json.dumps(str(api.parent))} }}
naga = "={NAGA_VERSION}"
serde = {{ version = "={versions["serde"]}", features = ["derive"] }}
serde_json = "={versions["serde_json"]}"
sha2 = "={versions["sha2"]}"

[patch.crates-io]
naga = {{ path = {json.dumps(str(naga_manifest.parent))} }}

[profile.dev]
debug = false
opt-level = 1
"""
        args = ["--manifest-path", manifest]
        lockfile = BUILD / "Cargo.lock"
        if not lockfile.exists() or not manifest.exists() or manifest.read_text() != content:
            manifest.write_text(content)
            lockfile.write_bytes(seed)
        try:
            metadata = json.loads(release.run(
                ["cargo", "metadata", "--format-version", "1", *args], cwd=BUILD, env=env, capture=True))
            packages = metadata["packages"]
            naga = [package for package in packages if package["name"] == "naga"]
            horizon = [package for package in packages if package["name"] == "horizon-shader-api"]
            resolved = tomllib.loads(lockfile.read_text())["package"]
            if (len(naga) != 1 or len(horizon) != 1
                    or naga[0]["version"] != NAGA_VERSION or naga[0]["source"] is not None
                    or Path(naga[0]["manifest_path"]).resolve() != naga_manifest.resolve()
                    or horizon[0]["source"] is not None
                    or Path(horizon[0]["manifest_path"]).resolve() != api.resolve()
                    or set(map(package_identity, resolved)) - set(map(package_identity, pinned))
                    != {("post-ir", "0.0.0", None, None)}):
                raise release.Refused("Post IR dependencies differ from the pinned Horizon lock or API path")
            features = next(node["features"] for node in metadata["resolve"]["nodes"]
                            if node["id"] == naga[0]["id"])
            api_naga = tomllib.loads(api.read_text())["dependencies"]["naga"]
            if set(features) != {"default", *api_naga["features"]}:
                raise release.Refused("Post IR resolved unexpected features on Horizon's Naga")
            release.run(["cargo", "build", "--locked", *args], cwd=BUILD, env=env, capture=True)
        except (release.Refused, OSError, ValueError):
            lockfile.unlink(missing_ok=True)
            raise
        release.verified_source(pin)
        dependencies = {
            "horizon_shader_api": {"cargo_id": horizon[0]["id"], "manifest": horizon[0]["manifest_path"],
                                   "version": horizon[0]["version"], "revision": HORIZON_REVISION},
            "naga": {"cargo_id": naga[0]["id"], "manifest": naga[0]["manifest_path"],
                     "version": NAGA_VERSION, "revision": HORIZON_REVISION, "features": features},
            "horizon_lock_sha256": hashlib.sha256(seed).hexdigest(),
            "checker_lock_sha256": release.digest(lockfile),
            "locked_transitives": [
                {key: package[key] for key in ("name", "version", "source", "checksum")}
                for package in resolved if package.get("source")
            ],
        }
        binary = BUILD / "target/debug/post-ir"
        return Checker(binary, dependencies, release.digest(binary))


def check(checker, pack):
    if release.digest(checker.binary) != checker.sha256:
        raise release.Refused("Built post IR checker changed before validation")
    policy_sha256 = release.digest(POLICY)
    result = subprocess.run([checker.binary, pack, POLICY], text=True, capture_output=True)
    if release.digest(checker.binary) != checker.sha256:
        raise release.Refused("Built post IR checker changed during validation")
    if release.digest(POLICY) != policy_sha256:
        raise release.Refused("Post IR continuity policy changed during validation")
    if result.returncode:
        raise release.Refused(result.stderr.strip() or f"Post IR checker exited {result.returncode}")
    return {**json.loads(result.stdout), "dependencies": checker.dependencies,
            "checker_sha256": checker.sha256, "policy_sha256": policy_sha256}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build")
    commands.add_parser("check").add_argument("pack", nargs="?", type=Path, default=release.PACK)
    args = parser.parse_args()
    try:
        checker = build()
        if args.command == "build":
            print(checker.binary)
        else:
            print(json.dumps(check(checker, args.pack), indent=2))
    except (release.Refused, OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
