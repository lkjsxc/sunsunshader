#!/usr/bin/env python3
"""Build and admit the exact archive using pinned, unmodified Horizon sources.

Use --latest for the build that works with the current public Horizon Nightly.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PIN_FILE = ROOT / "compatibility/horizon.json"


class Refused(RuntimeError):
    pass


def run(args, *, cwd=None, env=None, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                            text=True, capture_output=capture)
    if result.returncode:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        raise Refused(f"Command failed ({result.returncode}): {' '.join(map(str, args))}\n{detail}")
    return result.stdout.strip() if capture else None


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pins():
    data = json.loads(PIN_FILE.read_text())
    if data.get("schema") != 1:
        raise Refused("Unsupported compatibility pin schema")
    targets = data["targets"]
    nightly = targets["nightly"]
    if not nightly.get("tag", "").startswith("nightly-source/"):
        raise Refused("The release target must pin a public nightly-source tag, not development main")
    if not nightly.get("admission_source"):
        raise Refused("The release target must record its reviewed ordinary-game admission source")
    return targets


def clean_source(path):
    state = run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=path, capture=True)
    if state:
        raise Refused(f"Horizon source must be unmodified: {path}\n{state}")


def validator(target, pin):
    override = os.environ.get(f"SUNSUN_{target.upper()}_SOURCE")
    source = Path(override).resolve() if override else ROOT / ".build" / f"horizon-{target}"
    if not (source / ".git").exists():
        if override:
            raise Refused(f"Configured Horizon source is not a Git checkout: {source}")
        source.mkdir(parents=True, exist_ok=True)
        run(["git", "init", "--quiet", source])
        run(["git", "remote", "add", "origin", pin["repository"]], cwd=source)
        ref = f"refs/tags/{pin['tag']}:refs/tags/{pin['tag']}" if pin.get("tag") else pin["revision"]
        run(["git", "fetch", "--depth", "1", "origin", ref], cwd=source)
        run(["git", "checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd=source)
    clean_source(source)
    actual = run(["git", "rev-parse", "HEAD"], cwd=source, capture=True)
    if actual != pin["revision"]:
        raise Refused(f"Wrong Horizon source for {target}: {actual}; expected {pin['revision']}. "
                      "Use a fresh checkout when moving the pin.")
    if pin.get("tag"):
        tagged = run(["git", "rev-parse", f"refs/tags/{pin['tag']}^{{commit}}"], cwd=source, capture=True)
        if tagged != actual:
            raise Refused("Nightly source tag does not match its pinned commit")
    policy = pin.get("admission_source")
    if policy and digest(source / policy["path"]) != policy["sha256"]:
        raise Refused("Nightly game admission source changed. Review its ordinary game rules and update the pin.")
    env = os.environ.copy()
    env["CARGO_BUILD_JOBS"] = str(min(12, max(1, int(env.get("CARGO_BUILD_JOBS", "12")))))
    env["CARGO_INCREMENTAL"] = "0"
    env["CARGO_TARGET_DIR"] = str(source / "target")
    run(["cargo", "build", "--locked", "--profile", "fast", "--manifest-path", source / "Cargo.toml",
         "-p", "horizon-shader-api", "--bin", "horizon-shader"], cwd=source, env=env)
    clean_source(source)
    if run(["git", "rev-parse", "HEAD"], cwd=source, capture=True) != actual:
        raise Refused("Horizon source revision changed during the validator build")
    return source / "target/fast/horizon-shader"


def manifest(archive):
    with zipfile.ZipFile(archive) as package:
        return tomllib.loads(package.read("horizon-shaders.toml").decode("utf-8"))


def normal_game_admission(data, pin):
    # These are original assertions about the documented game contract, not a
    # copy of Horizon's implementation. Its audited source digest is in the pin.
    if data.get("api") != pin["normal_game_api"]:
        raise Refused(f"{pin['game_version']} normally draws API {pin['normal_game_api']}; "
                      f"archive declares {data.get('api')}. Experimental environment flags do not qualify.")
    for stage in pin.get("forbidden_sections", []):
        if stage in data:
            raise Refused(f"{pin['game_version']} does not admit [{stage}] in its normal configuration")


def official_check(binary, archive):
    result = subprocess.run([str(binary), "check", str(archive), "--json"],
                            text=True, capture_output=True)
    try:
        reports = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise Refused(f"Validator produced no readable report: {result.stderr}") from error
    if result.returncode or len(reports) != 1 or reports[0].get("ok") is not True:
        raise Refused(f"Pinned Horizon refused {archive}:\n{result.stdout}\n{result.stderr}")
    return reports[0]


def check_archive(binary, archive, target, pin):
    archive = Path(archive).resolve()
    if archive.suffix != ".hshader" or not archive.is_file():
        raise Refused("Check needs an existing .hshader file, not a source directory")
    before = digest(archive)
    report = official_check(binary, archive)
    data = manifest(archive)
    normal_game_admission(data, pin)
    if before != digest(archive) or report.get("sha256") != before:
        raise Refused("The archive changed during validation, or the validator checked different bytes")
    if report.get("id") != "sunsunshader" or report.get("version") != data.get("version"):
        raise Refused("The validator did not identify the expected Sunsun Shader archive")
    if not report.get("stages"):
        raise Refused("The archive has no validated shader stages")
    return {
        "schema": 1,
        "kind": "sunsunshader-compatibility-check",
        "scope": "Packed-file parser, shader validation and ordinary-game manifest admission; rendering is checked separately",
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "target": target,
        "archive": {"file": archive.name, "sha256": before, "bytes": archive.stat().st_size},
        "horizon": pin,
        "validator_sha256": digest(binary),
        "ordinary_game_admission": True,
        "pack_commit": run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture=True),
        "pack_worktree_clean": not bool(run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, capture=True)),
        "official_report": report,
    }


def write_receipt(archive, receipt):
    output = Path(str(archive) + ".check.json")
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    Path(str(archive) + ".sha256").write_text(f"{receipt['archive']['sha256']}  {Path(archive).name}\n")
    return output


def alter_manifest(archive, output, change):
    with zipfile.ZipFile(archive) as old, zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as new:
        for item in old.infolist():
            content = old.read(item.filename)
            if item.filename == "horizon-shaders.toml":
                content = change(content.decode()).encode()
            new.writestr(item, content)


def self_test(binary, archive, target, pin):
    with tempfile.TemporaryDirectory(prefix="gate-test-", dir=Path(archive).parent) as scratch:
        bad = Path(scratch) / "unknown-field.hshader"
        alter_manifest(archive, bad, lambda text: "sunsun_unknown_compatibility_probe = true\n" + text)
        result = subprocess.run([str(binary), "check", str(bad), "--json"], text=True, capture_output=True)
        if result.returncode == 0 or "unknown field" not in result.stdout or "sunsun_unknown_compatibility_probe" not in result.stdout:
            raise Refused("Negative gate test failed: the released parser must reject unknown manifest fields")
        if target == "nightly" and pin["normal_game_api"] == "0.1":
            experimental = Path(scratch) / "experimental-api.hshader"
            alter_manifest(archive, experimental, lambda text: text.replace('api = "0.1"', 'api = "0.2"', 1))
            official_check(binary, experimental)
            try:
                normal_game_admission(manifest(experimental), pin)
            except Refused:
                pass
            else:
                raise Refused("Negative gate test failed: experimental API 0.2 passed normal Nightly admission")
        print(f"{target}: negative packed-file admission checks passed", flush=True)


def archive_name(data, target):
    suffix = "" if target == "nightly" else "-main"
    return f"sunsunshader-{data['version']}{suffix}.hshader"


def build(target, pin, out_dir, test):
    binary = validator(target, pin)
    pack = ROOT / pin["pack_directory"]
    data = tomllib.loads((pack / "horizon-shaders.toml").read_text())
    normal_game_admission(data, pin)
    out_dir.mkdir(parents=True, exist_ok=True)
    final = out_dir / archive_name(data, target)
    with tempfile.TemporaryDirectory(prefix="package-", dir=out_dir) as scratch:
        candidate = Path(scratch) / final.name
        run([binary, "pack", pack, "--out", candidate])
        receipt = check_archive(binary, candidate, target, pin)
        if test:
            self_test(binary, candidate, target, pin)
        os.replace(candidate, final)
    # Packaging and checking are performed before the public output is replaced.
    receipt["official_report"]["path"] = str(final)
    write_receipt(final, receipt)
    print(f"PASS {target}: {final} ({receipt['archive']['sha256']})", flush=True)
    return final


def publish(archive, notes, title, dry_run, pin, prerelease=False, latest=False):
    # No GitHub write is reached before this exact immutable snapshot passes.
    staging = ROOT / ".build"
    staging.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="publish-", dir=staging) as scratch:
        snapshot = Path(scratch) / Path(archive).name
        shutil.copyfile(archive, snapshot)
        binary = validator("nightly", pin)
        receipt = check_archive(binary, snapshot, "nightly", pin)
        data = manifest(snapshot)
        if snapshot.name != archive_name(data, "nightly"):
            raise Refused("The release asset must have the versioned Nightly filename")
        rebuilt = Path(scratch) / "rebuilt.hshader"
        run([binary, "pack", ROOT / pin["pack_directory"], "--out", rebuilt])
        if digest(rebuilt) != receipt["archive"]["sha256"]:
            raise Refused("Release archive differs from the current pack source; rebuild and repeat the game captures")
        dirty = run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, capture=True)
        if dirty:
            raise Refused(f"Commit all release source and documentation first:\n{dirty}")
        if run(["git", "branch", "--show-current"], cwd=ROOT, capture=True) != "main":
            raise Refused("Publish from main")
        commit = receipt["pack_commit"]
        remote = run(["git", "ls-remote", "origin", "refs/heads/main"], cwd=ROOT, capture=True)
        if not remote or remote.split()[0] != commit:
            raise Refused("Push the exact checked source commit to origin/main before publishing")
        tag = f"v{data['version']}"
        refs = run(["git", "ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"], cwd=ROOT, capture=True)
        if refs:
            entries = dict(line.split()[::-1] for line in refs.splitlines())
            target = entries.get(f"refs/tags/{tag}^{{}}", entries.get(f"refs/tags/{tag}"))
            if target != commit:
                raise Refused("Existing release tag points at a different source commit")
        receipt_path = write_receipt(snapshot, receipt)
        if digest(snapshot) != receipt["archive"]["sha256"]:
            raise Refused("Release bytes changed after validation")
        command = ["gh", "release", "create", tag, snapshot, str(snapshot) + ".sha256", receipt_path,
                   "--repo", "lkjsxc/sunsunshader", "--target", commit,
                   "--title", title or f"Sunsun Shader {data['version']}", "--notes-file", notes]
        if latest:
            command.append("--latest")
        elif prerelease or "-" in data["version"]:
            command.append("--prerelease")
        if dry_run:
            print(f"PASS release dry run: {tag}, {receipt['archive']['sha256']}; no GitHub write performed")
        else:
            run(command, cwd=ROOT)
        write_receipt(Path(archive), receipt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("build", "check"):
        command = commands.add_parser(name)
        if name == "check":
            command.add_argument("archive", nargs="?")
        command.add_argument("--target", choices=["all", "nightly", "main"], default="all")
        command.add_argument("--out-dir", type=Path, default=ROOT / "dist")
        command.add_argument("--self-test", action="store_true")
    release = commands.add_parser("release")
    release.add_argument("archive", type=Path)
    release.add_argument("--notes", type=Path, required=True)
    release.add_argument("--title")
    release.add_argument("--dry-run", action="store_true")
    release_kind = release.add_mutually_exclusive_group()
    release_kind.add_argument("--prerelease", action="store_true", help="Publish as a pre-release")
    release_kind.add_argument("--latest", action="store_true",
                              help="Publish the build for the current public Nightly as GitHub Latest, even for an -rc version")
    args = parser.parse_args()
    targets = pins()
    if args.command == "release":
        if not args.notes.is_file():
            raise Refused("Release notes file does not exist")
        publish(args.archive.resolve(), args.notes.resolve(), args.title, args.dry_run, targets["nightly"],
                prerelease=args.prerelease, latest=args.latest)
    elif args.command == "check" and args.archive:
        if args.target == "all":
            raise Refused("Choose --target nightly or --target main when checking an existing archive")
        binary = validator(args.target, targets[args.target])
        archive = Path(args.archive).resolve()
        receipt = check_archive(binary, archive, args.target, targets[args.target])
        if args.self_test:
            self_test(binary, archive, args.target, targets[args.target])
        write_receipt(archive, receipt)
        print(f"PASS {args.target}: {archive} ({receipt['archive']['sha256']})")
    else:
        for target in targets if args.target == "all" else [args.target]:
            build(target, targets[target], args.out_dir.resolve(), args.self_test)


if __name__ == "__main__":
    try:
        main()
    except (Refused, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        sys.exit(1)
