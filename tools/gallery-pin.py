#!/usr/bin/env python3
"""Create a gallery input pin from a checked Sunsun pack and a signed Horizon Nightly."""
import argparse
import base64
import binascii
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

import release

ASSET = "horizon-linux-x86_64.tar.gz"
BINARIES = ("horizon-client", "horizon-ctl")
TRUSTED_KEYS = Path(__file__).with_name("gallery-horizon-keys.txt")


def sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def check_pack(pack, receipt, horizon):
    digest = sha256(pack)
    metadata = release.manifest(pack)
    release.normal_game_admission(metadata, horizon)
    official = receipt["official_report"]
    if not (
        receipt["schema"] == 1 and receipt["kind"] == "sunsunshader-compatibility-check"
        and receipt["target"] == "nightly" and receipt["horizon"] == horizon
        and receipt["ordinary_game_admission"] is True and receipt["pack_worktree_clean"] is True
        and re.fullmatch(r"[0-9a-f]{40}", receipt["pack_commit"])
        and receipt["archive"]["sha256"] == digest
        and receipt["archive"]["bytes"] == pack.stat().st_size
        and official["ok"] is True and official["sha256"] == digest and official["stages"]
        and official["id"] == metadata["id"] == "sunsunshader"
        and official["version"] == metadata["version"]
    ):
        raise ValueError("The pack requires its clean Nightly validation receipt for the current compatibility pin")
    return {
        "sha256": digest, "source_revision": receipt["pack_commit"],
        "id": metadata["id"], "version": metadata["version"],
        "frame_primaries": metadata.get("frame", {}).get("primaries", "bt709"),
    }


def check_signature(version, sums, signatures):
    key_prefix = bytes.fromhex("302a300506032b6570032100")
    keys = [
        base64.b64decode(line, validate=True)
        for line in TRUSTED_KEYS.read_text().splitlines() if line and not line.startswith("#")
    ]
    signature_bytes = [
        base64.b64decode(line, validate=True) for line in signatures.splitlines() if line
    ]
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        message, public_key, signature = (temp / name for name in ("message", "key", "sig"))
        message.write_bytes(f"horizon release {version}\n".encode() + sums)
        for key in keys:
            if len(key) != 32:
                raise ValueError("Invalid Horizon Ed25519 public key")
            public_key.write_bytes(key_prefix + key)
            for signed in signature_bytes:
                signature.write_bytes(signed)
                result = subprocess.run(
                    ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", public_key,
                     "-keyform", "DER", "-rawin", "-in", message, "-sigfile", signature],
                    capture_output=True,
                )
                if result.returncode == 0:
                    return
    raise ValueError(f"SHA256SUMS.v2.sig does not verify for {version}")


def check_nightly(horizon, archive, sums_path, signatures_path):
    version = horizon["launcher_version"]
    sums = sums_path.read_bytes()
    check_signature(version, sums, signatures_path.read_bytes())
    hashes = re.findall(rf"^([0-9a-f]{{64}}) [ *]{re.escape(ASSET)}$", sums.decode(), re.MULTILINE)
    archive_sha = sha256(archive)
    if hashes != [archive_sha]:
        raise ValueError(f"Signed SHA256SUMS does not identify these {ASSET} bytes")
    with tarfile.open(archive, "r:gz") as contents:
        result = {}
        for member in contents:
            name = Path(member.name).name
            if name not in BINARIES:
                continue
            if name in result or not member.isfile():
                raise ValueError(f"Unexpected member for {name}")
            with contents.extractfile(member) as handle:
                result[name] = hashlib.file_digest(handle, "sha256").hexdigest()
        if result.keys() != set(BINARIES):
            raise ValueError(f"{ASSET} is missing the Horizon capture binaries")
    return {
        "nightly": version, "source_revision": horizon["revision"],
        "archive_sha256": archive_sha, "binaries": dict(sorted(result.items())),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--nightly-archive", type=Path, required=True)
    parser.add_argument("--sums", type=Path, required=True)
    parser.add_argument("--signature", type=Path, required=True, help="SHA256SUMS.v2.sig")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    horizon = release.pins()["nightly"]
    checked = check_pack(args.pack, json.loads(args.receipt.read_text()), horizon)
    signed = check_nightly(horizon, args.nightly_archive, args.sums, args.signature)
    with args.output.open("x") as output:
        json.dump({"schema": 1, "pack": checked, "horizon": signed}, output, indent=2)
        output.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, release.Refused, binascii.Error, tarfile.TarError) as error:
        sys.exit(str(error))
