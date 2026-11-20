#!/usr/bin/env python3
"""Capture Sunsun gallery scenes with an isolated ordinary Horizon client."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime

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
    return subprocess.Popen([path], stdin=subprocess.DEVNULL, env=env)


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
            if guard.wait(timeout=18):
                raise RuntimeError("The CachyOS Wayland seat did not confirm 15 seconds of input inactivity")
            guard = idle_guard(args.idle_guard)
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
            renderer = subprocess.Popen(
                command, env=env, stdout=log, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, start_new_session=True,
            )
            while renderer.poll() is None:
                if remaining(args.deadline) < 20:
                    raise RuntimeError("GPU handback reached")
                if guard is not None and guard.poll() is not None:
                    if guard.returncode:
                        raise RuntimeError("The CachyOS Wayland seat stopped confirming inactivity")
                    guard = idle_guard(args.idle_guard)
                time.sleep(0.25)
        if renderer.returncode or not (args.output / "complete.json").exists():
            raise RuntimeError(f"Capture stopped. See {args.output / 'display.log'}")
    finally:
        if guard is not None and guard.poll() is None:
            guard.terminate()
            guard.wait(timeout=5)
        stop_group(renderer)


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


def bench_gpu(ctl, output, scene, renderer):
    ctl("options-set", "maxFps", 260)
    enabled = ctl("gpu-passes", "on")
    try:
        time.sleep(3)
        result = ctl("bench", 8, "raw", timeout=30)
    finally:
        disabled = ctl("gpu-passes", "off")
        ctl("options-set", "maxFps", 60)
    record(output / f"{scene}.timing.json", {
        "scene": scene, "renderer": renderer, "warmup_seconds": 3, "sample_seconds": 8,
        "format": "SDR", "profile": "Medium", "enable": enabled, "disable": disabled,
        "benchmark": result, "per_pass_available": bool(result.get("gpu_passes") and result.get("shader_passes")),
    })


def capture_group(args, pin, cfg, scenes, detail, lod, size):
    game = args.worker / f"game-{detail}-{lod}"
    pack_dir = game / "shaderpacks"
    pack_dir.mkdir(parents=True)
    pack = pin["pack"]
    installed_pack = pack_dir / f"{pack['id']}.hshader"
    shutil.copyfile(args.pack, installed_pack)
    verify(installed_pack, pack["sha256"])
    opts = pack_dir / ".horizon-options"
    opts.mkdir()
    (opts / f"{pack['id']}.txt").write_text("quality=1\n")
    (game / "options.txt").write_text("chunkSectionFadeInTime:0.0\n")
    (game / "horizon-graphics.txt").write_text(
        f"workers:4\nlodDistance:{lod}\nhdr:false\n"
        f"resolutionScale:100\ndynamicResolution:false\ntaa:false\nframeGeneration:off\n"
        f"shadowCache:false\npickedShaderPack:horizon:{pack['id']}\n"
    )
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
                ctl("tp", *trial["locate_origin"])
                located = ctl("command", "locate structure minecraft:trial_chambers")
                x, z = trial["located_xz"]
                match = rf"\[{x},\s*[^,]+,\s*{z}\]"
                if not any(re.search(match, line) for line in located.get("chat", [])):
                    raise RuntimeError(f"The generated trial chamber moved: {located}")
            previous_weather = "clear"
            for scene in scenes:
                print(f"Capturing {scene['id']}", flush=True)
                ctl("command", "tick unfreeze")
                ctl("tp", *scene["position"])
                ctl("look", *scene["look"])
                ctl("wait", 40)
                ctl("wait-ready", 120, timeout=130)
                ctl("command", "kill @e[type=!minecraft:player]")
                for command in cfg["setup"].get(scene.get("setup"), []):
                    ctl("command", command)
                ctl("time", scene["time"])
                ctl("command", "weather " + scene["weather"])
                ctl("wait", 120 if scene["weather"] != previous_weather or scene["weather"] == "rain" else 40)
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
                admission = {"kind": "native", "name": str(installed_pack)}
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
                if scene["id"] == args.timing_scene:
                    bench_gpu(ctl, args.output, scene["id"], status["renderer"])
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", required=True, type=Path)
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
    parser.add_argument("--scout", action="store_true", help="Use the smaller scouting output size")
    parser.add_argument("--timing-scene", help="Take one optional raw per-pass sample during a full GPU run")
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.backend == "gamescope" and (args.deadline is None or args.deadline.utcoffset() is None):
        parser.error("gamescope requires a timezone-aware --deadline")
    if args.backend == "software" and args.software_icd is None:
        parser.error("software requires --software-icd")
    args.catalogue = args.catalogue.resolve()
    args.pin = args.pin.resolve()
    pin = json.loads(args.pin.read_text())
    if pin.get("schema") != 1 or pin["pack"]["id"] != "sunsunshader":
        parser.error("expected a Sunsun Shader gallery input pin")
    cfg = json.loads(args.catalogue.read_text())
    scene_ids = [scene["id"] for scene in cfg["scenes"]]
    if (
        cfg.get("schema") != 1 or cfg["profile"] != "Medium"
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
        or args.timing_scene not in {scene["id"] for scene in scenes}
    ):
        parser.error("--timing-scene requires a selected scene in a 1080p Gamescope capture")
    for field in ("pack", "bin", "resources", "output"):
        setattr(args, field, getattr(args, field).resolve())

    if args.worker:
        # Horizon may update its decoded sprite cache under the resource root.
        shutil.copytree(args.resources, args.worker / "resources")
        groups = {}
        for scene in scenes:
            key = (scene.get("full_detail_chunks", cfg["full_detail_chunks"]), scene.get("lod_chunks", 0))
            groups.setdefault(key, []).append(scene)
        for (detail, lod), group in groups.items():
            capture_group(args, pin, cfg, group, detail, lod, size)
        record(args.output / "complete.json", {"scenes": [scene["id"] for scene in scenes]})
        return

    if (HERE.parent / ".git").exists() and args.output.is_relative_to(HERE.parent):
        if not args.output.is_relative_to(HERE.parent / ".build"):
            parser.error("Keep capture output under .build/ or outside this repository")
    verify(args.pack, pin["pack"]["sha256"])
    for name in BINARIES:
        verify(args.bin / name, pin["horizon"]["binaries"][name])
    if not args.resources.is_dir():
        parser.error("--resources must point to a prepared resource directory")
    args.output.mkdir(mode=0o700, parents=True)
    record(args.output / "inputs.json", {
        "nightly": pin["horizon"]["nightly"], "binaries": pin["horizon"]["binaries"],
        "pack_sha256": pin["pack"]["sha256"], "pack_version": pin["pack"]["version"],
        "horizon_archive_sha256": pin["horizon"]["archive_sha256"],
        "pin_sha256": sha256(args.pin),
        "catalogue_sha256": sha256(args.catalogue), "seed": cfg["seed"],
        "size": size, "format": "SDR", "backend": args.backend,
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
    except BaseException as error:
        record(args.output / "cleanup.json", {"completed": False, "reason": str(error) or "Capture interrupted"})
        raise
    record(args.output / "cleanup.json", {"completed": True, "temporary_game_removed": True})


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (KeyboardInterrupt, KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error) or "Capture interrupted")
