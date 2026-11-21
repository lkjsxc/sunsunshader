#!/usr/bin/env python3
"""Capture Sunsun gallery scenes with an isolated ordinary Horizon client."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime

import gallery_timing as timing

HERE = Path(__file__).resolve().parent
CATALOGUE = HERE / "gallery-scenes.json"
DEFAULT_PIN = HERE / "gallery-inputs.json"
BINARIES = ("horizon-client", "horizon-ctl")


def sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def record(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def verify(path, expected):
    if sha256(path) != expected:
        raise ValueError(f"Unexpected SHA-256 for {path}")


def stop_group(proc):
    if proc is None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def idle_guard(path):
    env = os.environ.copy()
    env.update(XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}", WAYLAND_DISPLAY="wayland-1")
    return subprocess.Popen([path, "--watch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0, env=env)


def remaining(deadline):
    if deadline is None:
        return float("inf")
    return (deadline - datetime.now(UTC)).total_seconds()


def supervise(args, work, env, width, height):
    guard = None
    renderer = None
    try:
        if args.backend == "gamescope":
            if remaining(args.deadline) < 40:
                raise RuntimeError("Too close to the GPU handback to start")
            guard = idle_guard(args.idle_guard)
            ready, _, _ = select.select([guard.stdout], [], [], 18)
            if not ready or guard.stdout.read(1) != b"R" or guard.poll() is not None:
                raise RuntimeError("The CachyOS Wayland seat did not confirm 15 seconds of input inactivity")
            display = [
                "gamescope", "--backend", "headless", "--expose-wayland",
                "--force-composition", "-w", str(width), "-h", str(height),
                "-W", str(width), "-H", str(height), "-r", "60", "--",
            ]
        else:
            display = ["xvfb-run", "-a", "-s", f"-screen 0 {width}x{height}x24 -nolisten tcp"]
            env.update(VK_DRIVER_FILES=str(args.software_icd), LIBGL_ALWAYS_SOFTWARE="1")
        cpus = ",".join(map(str, sorted(os.sched_getaffinity(0))[:4]))
        command = [
            "nice", "-n", "19", "taskset", "-c", cpus, *display,
            sys.executable, str(Path(__file__).resolve()), *sys.argv[1:],
            "--worker", str(work),
        ]
        with (args.output / "display.log").open("w") as log:
            if guard is not None and guard.poll() is not None:
                raise RuntimeError("The CachyOS Wayland input watch stopped before capture")
            renderer = subprocess.Popen(
                command, env=env, stdout=log, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, start_new_session=True,
            )
            while renderer.poll() is None:
                if remaining(args.deadline) < 20:
                    raise RuntimeError("GPU handback reached")
                if guard is not None and guard.poll() is not None:
                    raise RuntimeError("The CachyOS Wayland input watch stopped during capture")
                time.sleep(0.25)
        if guard is not None:
            if guard.poll() is not None:
                raise RuntimeError("The CachyOS Wayland input watch stopped before capture completion")
            try:
                if guard.stdin.write(b"F") != 1:
                    raise BrokenPipeError("Could not send finish marker")
                status = guard.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired) as error:
                raise RuntimeError("The CachyOS Wayland input watch could not confirm capture completion") from error
            if status:
                raise RuntimeError("The CachyOS Wayland input watch refused capture completion")
        if renderer.returncode or not (args.output / "complete.json").exists():
            raise RuntimeError(f"Capture stopped. See {args.output / 'display.log'}")
    finally:
        try:
            stop_group(renderer)
        finally:
            if guard is not None:
                if guard.poll() is None:
                    guard.terminate()
                    try:
                        guard.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        guard.kill()
                        guard.wait()
                guard.stdin.close()
                guard.stdout.close()


def check_sdr_png(path, size):
    with path.open("rb") as handle:
        header = handle.read(29)
    if (
        header[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
        or list(struct.unpack(">II", header[16:24])) != size
        or header[24] != 8
        or header[25] not in (2, 6)
    ):
        raise ValueError(f"Expected {size[0]}×{size[1]} 8-bit RGB(A) PNG at {path}")


def verify_pose(scene, state, status, world, detail, lod, size, backend):
    player = state["player"]
    device = status["renderer"]
    valid_device = (
        device["device_type"] == "cpu" and "llvmpipe" in device["gpu"].lower()
        if backend == "software" else device["device_type"] in {"integrated", "discrete"}
    )
    same_position = all(
        math.isclose(actual, expected, abs_tol=0.02)
        for actual, expected in zip(player["position"], scene["position"], strict=True)
    )
    same_look = all(
        abs(math.remainder(player[key] - expected, 360)) <= 0.02
        for key, expected in zip(("yaw", "pitch"), scene["look"], strict=True)
    )
    if not (
        same_position and same_look and state["world"] == world
        and state["dimension"] == "minecraft:overworld"
        and state["gamemode"] == "spectator"
        and state["time"]["day_time"] == scene["time"]
        and state["weather"]["raining"] == (scene["weather"] == "rain")
        and not state["weather"]["thundering"]
        and status["render_distance"] == detail and status["lod"]["distance"] == lod
        and valid_device and device["backend"] == "Vulkan"
        and device["size"] == size and device["resolution_scale"] == 100
    ):
        raise ValueError(f"Scene state diverged for {scene['id']}")


def graphics_text(lod, picked):
    """Both arms write these exact lines; a stock arm leaves `pickedShaderPack:` empty."""
    return (f"workers:4\nlodDistance:{lod}\nhdr:false\n"
            f"resolutionScale:100\ndynamicResolution:false\ntaa:false\nfxaa:false\nframeGeneration:off\n"
            f"shadowCache:false\npickedShaderPack:{picked}\n")


def shaderpack_listing(directory):
    """Every entry under shaderpacks/, hidden ones included; None when it is absent or a link."""
    if directory.is_symlink() or not directory.is_dir():
        return None
    entries = []
    for root, dirs, files in os.walk(directory):
        base = Path(root).relative_to(directory)
        entries += [(base / name).as_posix() + "/" for name in dirs]
        entries += [(base / name).as_posix() for name in files]
    return sorted(entries)


def step_world(ctl, count):
    """Advance a frozen private fixture exactly; loading waits must not set its phase."""
    start = ctl("simulation")["game_time"]
    ctl("command", f"tick step {count}")
    deadline = time.monotonic() + count / 20 + 30
    while True:
        current = ctl("simulation")["game_time"]
        if current == start + count:
            return
        if current > start + count or time.monotonic() >= deadline:
            raise RuntimeError("Frozen fixture did not advance by the exact requested tick count")
        ctl("wait", 5)


def bench_gpu(ctl, args, scene, installed_pack, options_file):
    """Retain the native reply unchanged, with observations bracketing the sample."""
    inputs = timing.read_json(args.output / "inputs.json")
    sample = {"warmup_seconds": args.timing_warmup, "seconds": args.timing_seconds}
    result = {"schema": 1, "kind": "sunsun-native-timing", "bench_format": timing.FORMAT,
              "inputs_sha256": sha256(args.output / "inputs.json"), "scene": scene, "sample": sample}

    expected = timing.STOCK_ADMISSION if args.stock else {"kind": "native", "name": str(installed_pack)}

    def admission(when):
        path = args.output / f"{scene['id']}.timing-{when}.png"
        reply = ctl("screenshot-sequence", 1, 100, path)
        if reply.get("pack") != expected:
            raise RuntimeError(f"{'Stock (no pack)' if args.stock else 'Native pack'} activation not verified {when} timing")
        check_sdr_png(path, inputs["size"])
        return reply

    def observe(active):
        observed = {"state": ctl("state"), "status": ctl("status"),
                    "world_game_time": ctl("simulation")["game_time"],
                    "options": ctl("options-get", *timing.OPTION_KEYS), "admission": active,
                    "installed_pack": None, "installed_pack_sha256": None, "pack_options": None, "blocks": []}
        if not args.stock:
            observed.update(installed_pack=str(installed_pack), installed_pack_sha256=sha256(installed_pack),
                            pack_options={})
            for line in options_file.read_text().splitlines():
                key, value = line.split("=", 1)
                if key in observed["pack_options"]:
                    raise ValueError("Duplicate installed shader option")
                observed["pack_options"][key] = float(value)
        for block in scene.get("check_blocks", []):
            reply = ctl("block", *block["position"])
            if not reply["loaded"] or reply["state"] != block["state"]:
                raise ValueError(f"Fixture block changed at {block['position']}")
            observed["blocks"].append({"position": block["position"], "state": reply["state"]})
        return observed

    try:
        active = admission("before")
        ctl("options-set", "maxFps", 260)  # The pinned client's unlimited slider setting.
        ctl("options-set", "enableVsync", "false")
        ctl("options-set", "inactivityFpsLimit", "minimized")
        result["reset"] = ctl("gpu-passes", "off")
        ctl("wait", 2)  # bench resets FrameStats, but does not clear the pass timers.
        result["reset_wait_frames"] = 2
        result["enable"] = ctl("gpu-passes", "on")
        time.sleep(args.timing_warmup)
        result["before"] = observe(active)
        timing.snapshot_key(result["before"], scene, inputs)
        result["conditions_before"] = timing.conditions()
        result["started_at"] = datetime.now(UTC).isoformat()
        result["benchmark"] = ctl("bench", args.timing_seconds, "raw", timeout=args.timing_seconds + 30)
        result["finished_at"] = datetime.now(UTC).isoformat()
        result["conditions_after"] = timing.conditions()
        result["after"] = observe(active)
        result["after"]["admission"] = admission("after")
    finally:
        # Even a failed activation/state check keeps any raw benchmark already returned.
        try:
            result["disable"] = ctl("gpu-passes", "off")
            ctl("options-set", "maxFps", 60)
        finally:
            record(args.output / f"{scene['id']}.timing.json", result)
    timing.validate_record(result, inputs, scene, sample)


def capture_group(args, pin, cfg, scenes, detail, lod, size):
    game = args.worker / f"game-{detail}-{lod}"
    pack_dir = game / "shaderpacks"
    pack_dir.mkdir(parents=True)
    pack = pin["pack"]
    if args.stock:
        # Stock Horizon: an existing, empty shaderpacks/ and no picked pack; nothing else differs.
        installed_pack = options_file = None
        picked = timing.STOCK_STAGING["picked_shader_pack"]
    else:
        installed_pack = pack_dir / f"{pack['id']}.hshader"
        shutil.copyfile(args.pack, installed_pack)
        verify(installed_pack, pack["sha256"])
        opts = pack_dir / ".horizon-options"
        opts.mkdir()
        options_file = opts / f"{pack['id']}.txt"
        options_file.write_text("".join(f"{key}={value}\n" for key, value in sorted(args.pack_options.items())))
        picked = f"horizon:{pack['id']}"
    (game / "options.txt").write_text("chunkSectionFadeInTime:0.0\n")
    (game / "horizon-graphics.txt").write_text(graphics_text(lod, picked))
    launched = shaderpack_listing(pack_dir)
    if args.stock and launched != timing.STOCK_STAGING["shaderpacks"]:
        raise RuntimeError(f"Stock shaderpacks/ is not empty at launch: {launched}")
    # Keep the socket path short and owned. The compositor and renderer share this run's group.
    socket = args.worker / f"ctl-{detail}-{lod}.sock"
    resources = args.worker / "resources"
    log_path = args.output / f"client-{detail}-{lod}.log"
    commands = args.output / f"commands-{detail}-{lod}.jsonl"

    def ctl(*words, timeout=90):
        argv = list(map(str, words))
        result = subprocess.run(
            [args.bin / "horizon-ctl", "--socket", socket, "--timeout", str(timeout), *argv],
            cwd=game, capture_output=True, text=True, timeout=timeout + 5,
        )
        if result.returncode:
            raise RuntimeError(f"{argv}: {result.stdout.strip()} {result.stderr.strip()}")
        reply = json.loads(result.stdout)
        with commands.open("a") as handle:
            handle.write(json.dumps({"command": argv, "reply": reply}) + "\n")
        if "error" in reply:
            raise RuntimeError(f"{argv}: {reply['error']}")
        return reply

    with log_path.open("w") as log:
        client = subprocess.Popen(
            [args.bin / "horizon-client", "--game-dir", game, "--world", cfg["world"],
             "--seed", str(cfg["seed"]), "--resources", resources, "--control-socket", socket,
             "--render-distance", str(detail), "--width", str(size[0]), "--height", str(size[1]),
             "--no-pause", "--offscreen"],
            cwd=game, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        )
        try:
            end = time.monotonic() + 120
            while not socket.exists():
                if client.poll() is not None or time.monotonic() >= end:
                    raise RuntimeError(f"Client startup failed. See {log_path}")
                time.sleep(0.1)
            ctl("hello")
            ctl("wait-ready", 120, timeout=130)
            seed = ctl("command", "seed")
            if not any(f"[{cfg['seed']}]" in line for line in seed.get("chat", [])):
                raise RuntimeError(f"Unexpected seed reply: {seed}")
            ctl("command", "gamemode spectator")
            ctl("command", "gamerule spawn_mobs false")
            ctl("command", "gamerule advance_time false")
            ctl("command", "gamerule advance_weather false")
            ctl("command", "gamerule random_tick_speed 0")
            ctl("options-set", "fov", cfg.get("fov", 70))
            ctl("options-set", "bobView", "false")
            ctl("options-set", "vignette", "false")
            ctl("options-set", "maxFps", 30 if args.backend == "software" else 60)
            ctl("key", "f1", "tap")
            if any(scene.get("trial_chamber") for scene in scenes):
                trial = cfg["trial_chamber"]
                origin = " ".join(map(str, trial["locate_origin"]))
                located = ctl("command", f"execute positioned {origin} run locate structure minecraft:trial_chambers")
                x, z = trial["located_xz"]
                match = rf"\[{x},\s*[^,]+,\s*{z}\]"
                if not any(re.search(match, line) for line in located.get("chat", [])):
                    raise RuntimeError(f"The generated trial chamber moved: {located}")
            previous_weather = "clear"
            for scene in scenes:
                print(f"Capturing {scene['id']}", flush=True)
                ctl("command", "tick freeze" if args.timing_scene else "tick unfreeze")
                ctl("tp", *scene["position"])
                ctl("look", *scene["look"])
                if args.timing_scene:
                    step_world(ctl, 40)
                else:
                    ctl("wait", 40)
                ctl("wait-ready", 120, timeout=130)
                ctl("command", "kill @e[type=!minecraft:player]")
                for command in cfg["setup"].get(scene.get("setup"), []):
                    ctl("command", command)
                ctl("time", scene["time"])
                ctl("command", "weather " + scene["weather"])
                settle = 120 if scene["weather"] != previous_weather or scene["weather"] == "rain" else 40
                if args.timing_scene:
                    step_world(ctl, settle)
                else:
                    ctl("wait", settle)
                previous_weather = scene["weather"]
                ctl("wait-ready", 120, timeout=130)
                ctl("command", "tick freeze")
                ctl("wait", 32)
                for block in scene.get("check_blocks", []):
                    seen = ctl("block", *block["position"])
                    if not seen["loaded"] or seen["state"] != block["state"]:
                        raise ValueError(f"Trial fixture diverged at {block['position']}: {seen}")
                if lod:
                    end = time.monotonic() + 90
                    while ctl("status")["lod"]["resident_quads"] == 0:
                        if time.monotonic() >= end:
                            raise RuntimeError("No distant terrain reached the renderer")
                        ctl("wait", 20)
                state, status = ctl("state"), ctl("status")
                record(args.output / f"{scene['id']}.state.json", {"state": state, "status": status})
                verify_pose(scene, state, status, cfg["world"], detail, lod, size, args.backend)
                path = args.output / f"{scene['id']}.png"
                admission = dict(timing.STOCK_ADMISSION if args.stock else {"kind": "native", "name": str(installed_pack)})
                if lod and args.stock:
                    raise RuntimeError("The client log cannot prove that no pack is active with LOD")
                if lod:
                    label = f"shader pack {pack['id']} {pack['version']}:"
                    if label not in log_path.read_text(errors="replace"):
                        raise RuntimeError("No native Sunsun admission in the client log")
                    receipt = ctl("screenshot", path)
                    admission["source"] = "client-log"
                else:
                    receipt = ctl("screenshot-sequence", 16, 100, path)
                    if receipt.get("pack") != admission:
                        raise RuntimeError(f"Unexpected active shader pack: {receipt.get('pack')}")
                    admission["source"] = "screenshot-sequence"
                check_sdr_png(path, size)
                record(args.output / f"{scene['id']}.capture.json", {
                    "receipt": receipt, "admission": admission,
                    "sha256": sha256(path), "size": size, "format": "SDR",
                })
                if scene["id"] in args.timing_scene:
                    bench_gpu(ctl, args, scene, installed_pack, options_file)
            ctl("quit", timeout=20)
            if client.wait(timeout=20):
                raise RuntimeError(f"Client quit with status {client.returncode}")
        finally:
            if client.poll() is None:
                client.terminate()
                try:
                    client.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait()
    # The parent copies these launch and quit listings into cleanup.json.
    staging = args.output / "staging.json"
    groups = timing.read_json(staging)["groups"] if staging.exists() else []
    quit_listing = shaderpack_listing(pack_dir)
    record(staging, {"groups": [*groups, {"full_detail_chunks": detail, "lod_chunks": lod,
                                          "launch": launched, "quit": quit_listing}]})
    if args.stock and quit_listing != timing.STOCK_STAGING["shaderpacks"]:
        raise RuntimeError(f"Stock shaderpacks/ is not empty after quit: {quit_listing}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, help="The pinned archive; omit it for a stock arm pin")
    parser.add_argument("--bin", required=True, type=Path, help="Verified Nightly binary directory")
    parser.add_argument("--pin", type=Path, default=DEFAULT_PIN, help="Input pin generated by gallery-pin.py")
    parser.add_argument("--resources", required=True, type=Path, help="Resources prepared for the pinned Horizon build")
    parser.add_argument("--output", required=True, type=Path, help="A new directory outside tracked files")
    parser.add_argument("--backend", choices=("software", "gamescope"), default="software")
    parser.add_argument("--software-icd", type=Path, help="Mesa lavapipe Vulkan ICD JSON")
    parser.add_argument("--idle-guard", type=Path, default=Path.home() / ".local/bin/edge-input-idle")
    parser.add_argument("--deadline", type=datetime.fromisoformat, help="GPU handback as an ISO 8601 timestamp with offset")
    parser.add_argument("--scene", action="append", help="Capture only this catalogue scene (repeatable)")
    parser.add_argument("--catalogue", type=Path, default=CATALOGUE, help="Use a generated scouting catalogue")
    parser.add_argument("--profile", choices=timing.PROFILES, help="Override the catalogue quality preset")
    parser.add_argument("--scout", action="store_true", help="Use the smaller scouting output size")
    parser.add_argument("--timing-scene", action="append", default=[], help="Take a native timing sample in this selected scene (repeatable)")
    parser.add_argument("--timing-warmup", type=float, default=10, help="Seconds to warm each scene after resetting pass history")
    parser.add_argument("--timing-seconds", type=float, default=8, help="Seconds of native raw frame data per scene")
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.backend == "gamescope" and (args.deadline is None or args.deadline.utcoffset() is None):
        parser.error("gamescope requires a timezone-aware --deadline")
    if args.backend == "software" and args.software_icd is None:
        parser.error("software requires --software-icd")
    args.catalogue = args.catalogue.resolve()
    args.pin = args.pin.resolve()
    pin = json.loads(args.pin.read_text())
    try:
        args.stock = timing.is_stock(pin)
        if args.stock:
            timing.check_pin(pin)
    except (timing.Invalid, KeyError, TypeError) as error:
        parser.error(f"invalid stock arm pin: {error}")
    if not args.stock and (pin.get("schema") != 1 or not isinstance(pin.get("pack"), dict)
                           or pin["pack"].get("id") != "sunsunshader"):
        parser.error("expected a Sunsun Shader gallery input pin")
    if args.stock != (args.pack is None):
        parser.error("a stock arm pin takes no --pack; a pack pin requires --pack")
    if args.stock and args.profile:
        parser.error("a stock arm has no shader pack preset; omit --profile")
    cfg = json.loads(args.catalogue.read_text())
    if args.profile:
        cfg["profile"] = args.profile
    scene_ids = [scene["id"] for scene in cfg["scenes"]]
    if (
        cfg.get("schema") != 1 or cfg["profile"] not in timing.PROFILES
        or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", cfg["world"])
        or not scene_ids or len(scene_ids) != len(set(scene_ids))
        or not all(re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value) for value in scene_ids)
    ):
        parser.error("invalid catalogue schema, profile, world or scene ids")
    scenes = [scene for scene in cfg["scenes"] if not args.scene or scene["id"] in args.scene]
    if args.scene and set(args.scene) != {scene["id"] for scene in scenes}:
        parser.error("unknown scene in --scene")
    size = cfg["scout_size" if args.scout else "capture_size"]
    if args.timing_scene and (
        args.backend != "gamescope" or size != [1920, 1080]
        or not set(args.timing_scene) <= {scene["id"] for scene in scenes}
        or len(args.timing_scene) != len(set(args.timing_scene))
        or not 3 <= args.timing_warmup <= 300 or not 1 <= args.timing_seconds <= 60
    ):
        parser.error("--timing-scene requires a selected scene in a 1080p Gamescope capture")
    if any(scene.get("lod_chunks", 0) and scene["id"] in args.timing_scene for scene in scenes):
        parser.error("timing activation proof is unavailable for LOD in this pin; select near scenes")
    if args.stock and any(scene.get("lod_chunks", 0) for scene in scenes):
        parser.error("no-pack activation proof is unavailable for LOD in this pin; select near scenes")
    for field in ("pack", "bin", "resources", "output"):
        if getattr(args, field) is not None:
            setattr(args, field, getattr(args, field).resolve())
    if args.stock:
        contract = {"pack_options": None, "expected_shader_passes": None}
    elif args.timing_scene:
        contract = timing.pack_contract(args.pack, pin, cfg["profile"])
    else:
        contract = {"pack_options": {"quality": timing.PROFILES.index(cfg["profile"])}, "expected_shader_passes": []}
    args.pack_options = contract["pack_options"]

    if args.worker:
        for name in BINARIES:
            verify(args.bin / name, pin["horizon"]["binaries"][name])
        # Horizon may update its decoded sprite cache under the resource root.
        shutil.copytree(args.resources, args.worker / "resources")
        if args.timing_scene:
            inputs = timing.read_json(args.output / "inputs.json")
            if (inputs["pack"] != pin["pack"] or inputs["horizon"] != pin["horizon"]
                    or inputs["pin_sha256"] != sha256(args.pin)
                    or inputs["catalogue_sha256"] != sha256(args.catalogue)
                    or inputs["capture_tool_sha256"] != sha256(Path(__file__))
                    or inputs["timing_tool_sha256"] != sha256(Path(timing.__file__))):
                raise ValueError("Capture code or pinned inputs changed before worker startup")
            if timing.resource_digest(args.worker / "resources") != inputs["resource_sha256"]:
                raise ValueError("Prepared resources changed during the private copy")
        groups = {}
        for scene in scenes:
            key = (scene.get("full_detail_chunks", cfg["full_detail_chunks"]), scene.get("lod_chunks", 0))
            groups.setdefault(key, []).append(scene)
        for (detail, lod), group in groups.items():
            capture_group(args, pin, cfg, group, detail, lod, size)
        record(args.output / "complete.json", {
            "scenes": [scene["id"] for scene in scenes], "inputs_sha256": sha256(args.output / "inputs.json"),
            "timings": {scene: sha256(args.output / f"{scene}.timing.json") for scene in args.timing_scene},
        })
        return

    if (HERE.parent / ".git").exists() and args.output.is_relative_to(HERE.parent):
        if not args.output.is_relative_to(HERE.parent / ".build"):
            parser.error("Keep capture output under .build/ or outside this repository")
    if not args.stock:
        verify(args.pack, pin["pack"]["sha256"])
    for name in BINARIES:
        verify(args.bin / name, pin["horizon"]["binaries"][name])
    if not args.resources.is_dir():
        parser.error("--resources must point to a prepared resource directory")
    args.output.mkdir(mode=0o700, parents=True)
    record(args.output / "inputs.json", {
        "schema": 2, "kind": "sunsun-gallery-inputs", "pack": pin["pack"], "horizon": pin["horizon"],
        "resource_sha256": timing.resource_digest(args.resources) if args.timing_scene else None,
        "capture_tool_sha256": sha256(Path(__file__)), "timing_tool_sha256": sha256(Path(timing.__file__)),
        **({"arm": "stock", "staging": timing.STOCK_STAGING} if args.stock else {}),
        "profile": None if args.stock else cfg["profile"], **contract, "world": cfg["world"], "fov": cfg.get("fov", 70),
        "full_detail_chunks": cfg["full_detail_chunks"], "machine": timing.machine_identity(),
        "graphics": timing.GRAPHICS,
        "nightly": pin["horizon"]["nightly"], "binaries": pin["horizon"]["binaries"],
        "pack_sha256": None if args.stock else pin["pack"]["sha256"],
        "pack_version": None if args.stock else pin["pack"]["version"],
        "horizon_archive_sha256": pin["horizon"]["archive_sha256"],
        "pin_sha256": sha256(args.pin),
        "catalogue_sha256": sha256(args.catalogue), "seed": cfg["seed"],
        "size": size, "format": "SDR", "backend": args.backend,
        "render_mode": "offscreen",
    })
    try:
        with tempfile.TemporaryDirectory(prefix="sunsun-gallery-", dir="/tmp") as directory:
            work = Path(directory)
            env = {key: os.environ[key] for key in ("PATH", "LD_LIBRARY_PATH") if key in os.environ}
            for key in ("HOME", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                        "XDG_DATA_HOME", "XDG_STATE_HOME", "HORIZON_HOME", "HORIZON_LAUNCHER_HOME", "TMPDIR"):
                path = work / key.lower()
                path.mkdir(mode=0o700)
                env[key] = str(path)
            env.update(
                LANG="C.UTF-8", HORIZON_NO_AUDIO="1", HORIZON_LAUNCHER_NO_SELF_UPDATE="1",
                HORIZON_STILL="1", WGPU_BACKEND="vulkan", RAYON_NUM_THREADS="4",
                OMP_NUM_THREADS="4", LP_NUM_THREADS="4",
            )
            supervise(args, work, env, *size)
        staging = timing.read_json(args.output / "staging.json")["groups"]
    except BaseException as error:
        record(args.output / "cleanup.json", {"completed": False, "reason": str(error) or "Capture interrupted"})
        raise
    record(args.output / "cleanup.json", {"completed": True, "temporary_game_removed": True, "staging": staging})


def interrupted(_signum, _frame):
    timing.interrupted(_signum, _frame)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except (KeyboardInterrupt, KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error) or "Capture interrupted")
