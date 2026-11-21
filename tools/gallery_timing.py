#!/usr/bin/env python3
"""Plan, run and reduce private paired native timings through gallery-capture.py."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys

import release

HERE = Path(__file__).resolve().parent
REVISION = "5ef7734fdd854add5efd6817178be3c988d8d050"
FORMAT = "horizon-bench-5ef7734-v1"
PROFILES = ("Low", "Medium", "High")
RENDERER_KEYS = (
    "gpu", "vendor", "driver", "device_type", "backend", "size", "present_mode",
    "resolution_scale", "dynamic_resolution", "msaa_requested", "msaa_samples",
    "gpu_culling_mode", "gpu_culling", "packed_layout",
)
OPTION_KEYS = ("fov", "maxFps", "enableVsync", "inactivityFpsLimit", "bobView", "vignette", "gamma")
GRAPHICS = {"workers": 4, "hdr": False, "resolutionScale": 100, "dynamicResolution": False,
            "taa": False, "fxaa": False, "frameGeneration": "off", "shadowCache": False}
CORE_PASSES = {"World", "World after copy", "Native shader pack shadow",
               "Native shader pack translucent shadow"}
# Stock arm A: the same signed client with no shader pack. The screenshot-sequence reply
# (game/runtime/screenshot_sequence.rs:162-165) names no pack, and no pack-only renderer row
# may appear. Its full renderer label set is measured by its first run, never hard-coded.
STOCK_ADMISSION = {"kind": "none", "name": None}
STOCK_STAGING = {"shaderpacks": [], "picked_shader_pack": ""}
STOCK_FORBIDDEN_PASSES = {"Native shader pack shadow", "Native shader pack translucent shadow",
                          "World after copy", "Flatten", "Flatten phase 2"}
STOCK_DROPPED_KEYS = ("profile", "pack_options", "expected_shader_passes")
# The only metrics a stock-relative suite differences; the arms time different pass sets.
WHOLE_FRAME = ("CPU work p50", "GPU span p50", "elapsed frame p50", "elapsed frame p95")
LIMIT = 1 << 20


class Invalid(ValueError):
    """Evidence is incomplete or cannot be compared under this contract."""


def require(condition, message):
    if not condition:
        raise Invalid(message)


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=no_duplicates,
                      parse_constant=lambda value: (_ for _ in ()).throw(Invalid(f"non-finite JSON: {value}")))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def private_output(path):
    path = Path(path).resolve()
    root = HERE.parent
    require(not path.is_relative_to(root) or path.is_relative_to(root / ".build"),
            "Keep timing records under .build/ or outside this repository")
    path.mkdir(mode=0o700, parents=True)
    return path


def resource_digest(root):
    """Identify the prepared input bytes, including filenames; never mutate them."""
    result = hashlib.sha256()
    paths = sorted(path for path in Path(root).rglob("*") if path.is_file())
    require(paths, "prepared resources are empty")
    for path in paths:
        result.update(path.relative_to(root).as_posix().encode() + b"\0")
        result.update(bytes.fromhex(digest(path)))
    return result.hexdigest()


def machine_identity():
    return {"host": platform.node(), "system": platform.system(), "kernel": platform.release(),
            "architecture": platform.machine(), "cpu_affinity": sorted(os.sched_getaffinity(0))}


def conditions():
    """Read-only context, not a thermal correction or an assertion of idle hardware."""
    def files(pattern):
        return {str(path): path.read_text().strip() for path in sorted(Path("/sys").glob(pattern))
                if path.is_file() and os.access(path, os.R_OK)}
    return {"load_average": list(os.getloadavg()),
            "power_online": files("class/power_supply/*/online"),
            "cpu_governors": files("devices/system/cpu/cpu*/cpufreq/scaling_governor"),
            "temperatures_millidegrees": files("class/thermal/thermal_zone*/temp")}


def check_hash(value, length=64):
    require(isinstance(value, str) and re.fullmatch(rf"[0-9a-f]{{{length}}}", value),
            f"missing or invalid {length}-digit identity")


def is_stock(value):
    """True only for an explicit stock arm declaration; any other declared arm is refused."""
    arm = value.get("arm")
    require(arm in (None, "stock"), f"unknown arm declaration: {arm!r}")
    return arm == "stock"


def check_pin(pin):
    horizon, pack = pin["horizon"], pin["pack"]
    if is_stock(pin):
        # A stock pin names only the signed client. A null pack is never accepted without it.
        require(pin["schema"] == 1 and set(pin) == {"schema", "arm", "horizon", "pack"} and pack is None,
                "a stock pin is exactly {schema: 1, arm: stock, horizon, pack: null}")
    else:
        require(pin["schema"] == 1 and isinstance(pack, dict) and pack.get("id") == "sunsunshader",
                "unsupported gallery pin")
    require(horizon["source_revision"] == REVISION and
            horizon["nightly"] == "nightly-2026-11-19-5ef7734", "unsupported native bench source pin")
    if pack is not None:
        require(pack["frame_primaries"] == "bt709", "timing requires the pinned SDR BT.709 contract")
        check_hash(pack["sha256"])
        check_hash(pack["source_revision"], 40)
        require(isinstance(pack["version"], str) and pack["version"], "missing pack version")
    check_hash(horizon["archive_sha256"])
    require(set(horizon["binaries"]) == {"horizon-client", "horizon-ctl"}, "missing binary identities")
    for value in horizon["binaries"].values():
        check_hash(value)


def pack_contract(archive, pin, profile):
    check_pin(pin)
    require(digest(archive) == pin["pack"]["sha256"], "pack bytes differ from input pin")
    manifest = release.manifest(archive)
    release.normal_game_admission(manifest, release.nightly_pin())
    require(manifest["id"] == pin["pack"]["id"] and manifest["version"] == pin["pack"]["version"],
            "pack manifest differs from input pin")
    require(profile in PROFILES, "unknown quality preset")
    options = {}
    for option in manifest["options"]:
        key, kind, value = option["id"], option["type"], option["default"]
        if key == "quality":
            require(kind == "choice" and tuple(option["values"]) == PROFILES, "unsupported quality option")
            value = profile
        if kind == "choice":
            value = option["values"].index(value)
        elif kind == "bool":
            require(type(value) is bool, f"invalid boolean default for {key}")
            value = int(value)
        else:
            require(kind in {"float", "int"}, f"unsupported option type for {key}")
            number(value, f"default for {key}")
        require(key not in options, f"duplicate option {key}")
        options[key] = value
    require(options.get("quality") == PROFILES.index(profile), "missing quality option")
    require(options.get("shadows") == 1 and "shadow" in manifest,
            "this pass contract requires Sunsun's native shadow maps")
    stages = [*manifest.get("before_world", []), manifest["sky"], *manifest.get("post", []),
              manifest.get("tonemap", {"name": "Tonemap"})]
    names = [stage.get("name") or stage["file"] for stage in stages]
    require(len(names) == len(set(names)), "duplicate timed stage labels cannot be paired separately")
    return {"pack_options": options, "expected_shader_passes": sorted(names)}


def number(value, label, *, positive=False):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0 and
            (not positive or value > 0), f"{label}: expected finite {'positive' if positive else 'nonnegative'} number")
    return value


def quantile(values, fraction):
    """Pinned FrameStats' nearest-rank quantile, including its even-N median."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def close(actual, expected, label):
    number(actual, label)
    require(math.isclose(actual, expected, rel_tol=2e-6, abs_tol=1e-6), f"{label} disagrees with raw samples")


def native_metrics(bench, expected_shader_passes, *, stock=False):
    """Validate the checked-in format; retain the original object outside this reducer.

    A stock arm has no expected pack passes and must report none.
    """
    require(stock == (expected_shader_passes is None), "stock arm and expected pack passes disagree")
    require(type(bench["frames"]) is int and 0 < bench["frames"] < LIMIT, "empty or saturated native frame record")
    metrics = {}
    for field, scope in (("frame_ms", "elapsed frame"), ("cpu_ms", "CPU work"), ("gpu_ms", "GPU span")):
        values = bench[field]
        require(isinstance(values, list) and 0 < len(values) < LIMIT, f"{field}: missing or saturated raw series")
        for value in values:
            number(value, field, positive=field == "frame_ms")
        require(any(value > 0 for value in values), f"{field}: no positive samples")
        if field == "frame_ms":
            require(len(values) == bench["frames"], "frames differs from frame_ms length")
            close(bench["seconds"], math.fsum(values) / 1000, "seconds")
            native = bench
        else:
            native = bench[field[:-3]]
            require(isinstance(native, dict), f"{field}: missing native summary")
            close(native["avg_ms"], math.fsum(values) / len(values), field + " average")
        for key, fraction in (("p50_ms", .5), ("p95_ms", .95), ("p99_ms", .99), ("max_ms", 1)):
            close(native[key], quantile(values, fraction), field + " " + key)
        metrics[f"{scope} p50"] = quantile(values, .5)
        if field == "frame_ms":
            metrics[f"{scope} p95"] = quantile(values, .95)
    # GPU samples arrive asynchronously. Never zip the three arrays by frame index.
    fields = (("gpu_passes", "renderer"),) if stock else (("gpu_passes", "renderer"), ("shader_passes", "pack"))
    if stock:
        # The stock raw format has no shader_passes key; an empty map is the only other admitted form.
        require(bench.get("shader_passes", {}) == {}, "stock arm reports shader pack passes")
    for field, prefix in fields:
        passes = bench[field]
        require(isinstance(passes, dict) and passes, f"missing {field}")
        require(all(isinstance(key, str) and key for key in passes), f"invalid labels in {field}")
        if field == "shader_passes":
            require(set(passes) == set(expected_shader_passes),
                    f"shader pass set mismatch: missing={sorted(set(expected_shader_passes) - set(passes))}, "
                    f"unexpected={sorted(set(passes) - set(expected_shader_passes))}")
        elif stock:
            require("World" in passes, "missing renderer passes: ['World']")
            require(not STOCK_FORBIDDEN_PASSES & set(passes),
                    f"stock arm reports pack renderer passes: {sorted(STOCK_FORBIDDEN_PASSES & set(passes))}")
        else:
            require(CORE_PASSES <= set(passes), f"missing renderer passes: {sorted(CORE_PASSES - set(passes))}")
        for name, value in passes.items():
            metrics[f"{prefix}: {name}"] = number(value, f"{field}.{name}")
    return metrics


def snapshot_key(snapshot, scene, inputs):
    """Recheck recorded observations, not just a capture-side `valid` flag."""
    state, status = snapshot["state"], snapshot["status"]
    player, renderer = state["player"], status["renderer"]
    require(all(isinstance(renderer[key], str) and renderer[key]
                for key in ("gpu", "vendor", "driver", "device_type", "backend", "present_mode", "gpu_culling_mode"))
            and type(renderer["gpu_culling"]) is bool, "missing renderer identity or active culling state")
    require(type(snapshot["world_game_time"]) is int and snapshot["world_game_time"] >= 0,
            "missing authoritative world animation clock")
    require(state["world"] == inputs["world"] and state["dimension"] == "minecraft:overworld"
            and state["gamemode"] == "spectator" and state["paused"] is False
            and status["screen"] == "playing" and player["effects"] == [], "world, mode, pause or effects mismatch")
    require(len(player["position"]) == len(scene["position"]) == 3, "invalid position")
    require(all(math.isclose(a, b, rel_tol=0, abs_tol=.02)
                for a, b in zip(player["position"], scene["position"])), "camera position mismatch")
    require(all(abs(math.remainder(player[key] - angle, 360)) <= .02
                for key, angle in zip(("yaw", "pitch"), scene["look"], strict=True)), "camera angle mismatch")
    require(state["time"]["day_time"] == scene["time"] and
            state["weather"] == {"raining": scene["weather"] == "rain", "thundering": False}, "time or weather mismatch")
    require(status["render_distance"] == scene.get("full_detail_chunks", inputs["full_detail_chunks"])
            and status["lod"]["distance"] == scene.get("lod_chunks", 0), "render distances mismatch")
    require(renderer["size"] == inputs["size"] and renderer["resolution_scale"] == 100
            and renderer["dynamic_resolution"] is False and renderer["backend"] == "Vulkan", "framebuffer/backend mismatch")
    require((inputs["backend"] == "gamescope" and renderer["device_type"] in {"integrated", "discrete"})
            or (inputs["backend"] == "software" and renderer["device_type"] == "cpu"
                and "llvmpipe" in renderer["gpu"].lower()), "backend/device mismatch")
    options = {key: snapshot["options"]["options"][key]["value"] for key in OPTION_KEYS}
    number(options["gamma"], "gamma")
    require(options["fov"] == inputs["fov"] and options["maxFps"] == 260
            and options["inactivityFpsLimit"] == "minimized"
            and options["enableVsync"] is False and options["bobView"] is False
            and options["vignette"] is False, "observed options mismatch")
    if is_stock(inputs):
        require(snapshot["admission"]["pack"] == STOCK_ADMISSION, "stock activation not verified: a pack is active")
        require(snapshot["installed_pack"] is None and snapshot["installed_pack_sha256"] is None
                and snapshot["pack_options"] is None, "stock arm observed an installed pack or pack options")
    else:
        expected_pack = {"kind": "native", "name": snapshot["installed_pack"]}
        require(snapshot["admission"]["pack"] == expected_pack, "native pack activation not verified")
        require(Path(snapshot["installed_pack"]).name == "sunsunshader.hshader", "unexpected installed pack")
        require(snapshot["installed_pack_sha256"] == inputs["pack"]["sha256"], "installed pack bytes mismatch")
        require(snapshot["pack_options"] == inputs["pack_options"], "installed preset/options mismatch")
    require(snapshot["blocks"] == scene.get("check_blocks", []), "fixture block observations missing or different")
    if scene.get("lod_chunks", 0):
        require(status["lod"]["resident_quads"] > 0, "no resident LOD terrain")
    return {"renderer": {key: renderer[key] for key in RENDERER_KEYS}, "options": options,
            "world_game_time": snapshot["world_game_time"],
            "resident_sections": renderer["resident_sections"],
            "lod_resident_quads": status["lod"]["resident_quads"],
            "lod_levels": status["lod"]["levels"]}


def validate_record(record, inputs, scene, sample):
    require(inputs["schema"] == 2 and inputs["kind"] == "sunsun-gallery-inputs", "old or unknown input metadata")
    stock = is_stock(inputs)
    check_pin({"schema": 1, **({"arm": "stock"} if stock else {}), "horizon": inputs["horizon"], "pack": inputs["pack"]})
    for field in ("resource_sha256", "catalogue_sha256", "capture_tool_sha256", "timing_tool_sha256"):
        check_hash(inputs[field])
    if stock:
        require(inputs["profile"] is None and inputs["pack_options"] is None
                and inputs["expected_shader_passes"] is None and inputs["staging"] == STOCK_STAGING,
                "stock arm inputs carry a pack preset, options, passes or staging")
    else:
        require(inputs["profile"] in PROFILES and
                inputs["pack_options"]["quality"] == PROFILES.index(inputs["profile"]), "profile/options mismatch")
    require(inputs["format"] == "SDR" and inputs["size"] == [1920, 1080], "unsupported capture format")
    require(inputs["render_mode"] == "offscreen", "missing or unsupported rendering/presentation path")
    require(inputs["graphics"] == GRAPHICS, "missing or unsupported native graphics settings")
    require(type(inputs["seed"]) is int and isinstance(inputs["world"], str) and inputs["world"], "missing world identity")
    require(all(isinstance(inputs["machine"][key], str) and inputs["machine"][key]
                for key in ("host", "system", "kernel", "architecture")) and inputs["machine"]["cpu_affinity"],
            "missing machine identity")
    require(record["schema"] == 1 and record["kind"] == "sunsun-native-timing"
            and record["bench_format"] == FORMAT, "unsupported timing format; old samples cannot be upgraded by assumption")
    require(record["scene"] == scene and record["sample"] == sample, "scene or sampling protocol mismatch")
    require(record["enable"]["ok"] is True and record["enable"]["gpu_passes"] is True
            and record["enable"]["detail"] is False and record["disable"]["ok"] is True
            and record["disable"]["gpu_passes"] is False, "pass timing switches not verified")
    require(record["reset"]["gpu_passes"] is False and record["reset_wait_frames"] >= 2,
            "missing off/render/on pass-history reset")
    before = snapshot_key(record["before"], scene, inputs)
    after = snapshot_key(record["after"], scene, inputs)
    require(before == after, "scene, device, options or resident geometry changed during the sample")
    start, end = (datetime.fromisoformat(record[key]) for key in ("started_at", "finished_at"))
    require(start.utcoffset() is not None and end.utcoffset() is not None and end > start,
            "invalid sample timestamps")
    require((end - start).total_seconds() >= sample["seconds"], "sample finished before its requested duration")
    for stage in ("conditions_before", "conditions_after"):
        for key in ("load_average", "power_online", "cpu_governors", "temperatures_millidegrees"):
            require(key in record[stage], f"missing {stage}.{key}")
    for key in ("power_online", "cpu_governors"):
        require(record["conditions_before"][key] == record["conditions_after"][key], f"{key} changed during sample")
    key = {field: inputs[field] for field in (
        "horizon", "resource_sha256", "catalogue_sha256", "capture_tool_sha256", "timing_tool_sha256",
        "world", "seed", "profile", "pack_options", "size", "format", "backend", "render_mode", "fov",
        "full_detail_chunks", "graphics", "machine", "expected_shader_passes")}
    key.update(observed=before, scene=scene, sample=sample,
               power_online=record["conditions_before"]["power_online"],
               cpu_governors=record["conditions_before"]["cpu_governors"])
    metrics = native_metrics(record["benchmark"], inputs["expected_shader_passes"], stock=stock)
    # A command boundary can include a partial neighbouring frame, not an arbitrary truncated window.
    tolerance = max(.25, 2 * max(record["benchmark"]["frame_ms"]) / 1000)
    require(abs(record["benchmark"]["seconds"] - sample["seconds"]) <= tolerance,
            "native elapsed duration does not cover the requested sample")
    return key, metrics


def schedule(rounds):
    require(type(rounds) is int and 2 <= rounds <= 20, "use 2..20 four-run rounds")
    return [{"index": i * 4 + j, "round": i, "arm": arm,
             "directory": f"{i * 4 + j + 1:03d}-{arm}"}
            for i in range(rounds) for j, arm in enumerate("ABBA" if i % 2 == 0 else "BAAB")]


def checked_file(root, relative, expected):
    path = root / relative
    require(not path.is_symlink() and path.resolve().is_relative_to(root.resolve()), "record escapes its capture directory")
    check_hash(expected)
    require(digest(path) == expected, f"record hash mismatch: {relative}")
    return read_json(path)


def interval(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "n": len(values)}


def declared_isolation_keys(delta):
    """The only opt-in profile variations admitted by this private experiment.

    A declaration must be exact, ordered and identical to the source-tested
    builder's options. Never suppress accidental settings drift or pass loss.
    """
    if delta is None:
        return ()
    if delta == {"id": "light_medium_pair", "A": 1, "B": 0}:
        return ("local_haze", "clouds")
    for option in ("local_haze", "clouds", "water_reflections", "weather_detail"):
        if delta == {"id": option, "A": 1, "B": 0}:
            return (option,)
    raise Invalid("unapproved or malformed option isolation")


def stock_arm(pins):
    """Return "A" for a stock-relative suite or None for pack against pack; nothing else exists."""
    stock = {arm for arm, pin in pins.items() if is_stock(pin)}
    require(stock in (set(), {"A"}), "a suite admits exactly one stock arm, and it is A")
    return "A" if stock else None


def common_conditions(key):
    """The condition key both arms of a stock-relative suite must share."""
    return {field: value for field, value in key.items() if field not in STOCK_DROPPED_KEYS}


def reduce_suite(root):
    root = Path(root)
    suite = read_json(root / "suite.json")
    require(suite["schema"] == 1 and suite["kind"] == "sunsun-native-timing-suite"
            and suite["bench_format"] == FORMAT, "unsupported suite format")
    require(suite["evidence"] in {"measurement", "synthetic-fixture"}, "missing evidence classification")
    require(suite["render_mode"] == "offscreen", "unsupported suite presentation path")
    require(suite["complete"] is True, "suite incomplete; do not select only successful runs")
    require(3 <= number(suite["sample"]["warmup_seconds"], "warmup") <= 300 and
            1 <= number(suite["sample"]["seconds"], "sample duration") <= 60, "unsupported sampling duration")
    planned = schedule(suite["rounds"])
    require(len(suite["runs"]) == len(planned), "incomplete interleaving schedule")
    require(suite["scenes"] and len({s["id"] for s in suite["scenes"]}) == len(suite["scenes"]), "invalid scene list")
    for pin in suite["pins"].values():
        check_pin(pin)
    require(set(suite["pins"]) == {"A", "B"} and
            suite["pins"]["A"]["horizon"] == suite["pins"]["B"]["horizon"], "two matching Horizon pins required")
    stock = stock_arm(suite["pins"])
    require(suite.get("stock_arm") == stock, "declared stock arm differs from the pins")
    delta = suite.get("option_delta")
    if stock:
        require(delta is None, "option isolation compares two packs; a stock arm has no options")
        contract = suite.get("pack_contract")
        require(isinstance(contract, dict) and set(contract) == {"pack_options", "expected_shader_passes"}
                and isinstance(contract["pack_options"], dict) and contract["pack_options"]
                and contract["pack_options"].get("quality") == PROFILES.index(suite["profile"])
                and isinstance(contract["expected_shader_passes"], list) and contract["expected_shader_passes"],
                "stock-relative suite lacks B's planned preset contract")
    else:
        require(suite["pins"]["A"]["pack"]["sha256"] != suite["pins"]["B"]["pack"]["sha256"],
                "A and B identify the same pack bytes")
    delta_keys = declared_isolation_keys(delta)
    by_scene = {scene["id"]: [] for scene in suite["scenes"]}
    identities, previous_end = {}, None
    for planned_run, run in zip(planned, suite["runs"], strict=True):
        label = run.get("directory", "unknown run")
        try:
            require({key: run[key] for key in planned_run} == planned_run, "interleaving order changed")
            directory = root / planned_run["directory"]
            require(not directory.is_symlink(), "capture directory is a symlink")
            complete = checked_file(directory, "complete.json", run["complete_sha256"])
            require(complete["scenes"] == [s["id"] for s in suite["scenes"]], "capture scene list differs")
            require(set(complete["timings"]) == set(by_scene), "missing timing scene")
            cleanup = checked_file(directory, "cleanup.json", run["cleanup_sha256"])
            require(cleanup["completed"] is True and cleanup["temporary_game_removed"] is True, "capture cleanup incomplete")
            inputs = checked_file(directory, "inputs.json", complete["inputs_sha256"])
            pin = suite["pins"][run["arm"]]
            arm_stock = is_stock(pin)
            require(inputs["pack"] == pin["pack"] and inputs["horizon"] == pin["horizon"]
                    and is_stock(inputs) == arm_stock, "run differs from planned exact pack/client")
            require(inputs["profile"] == (None if arm_stock else suite["profile"])
                    and inputs["catalogue_sha256"] == suite["catalogue_sha256"]
                    and inputs["resource_sha256"] == suite["resource_sha256"], "run differs from planned inputs")
            if arm_stock:
                # shaderpacks/ is listed when the client starts and again after it quits.
                require(isinstance(cleanup["staging"], list) and cleanup["staging"]
                        and all(group["launch"] == STOCK_STAGING["shaderpacks"] == group["quit"]
                                for group in cleanup["staging"]), "stock shaderpacks/ was not empty at launch and quit")
            elif stock:
                require({key: inputs[key] for key in contract} == contract,
                        "pack arm differs from its planned preset contract")
            identities[run["arm"]] = inputs["pack"]
            for option in delta_keys:
                require(inputs["pack_options"].get(option) == delta[run["arm"]],
                        "isolated option does not match its arm")
            first_start, last_end = None, None
            for scene in suite["scenes"]:
                record = checked_file(directory, scene["id"] + ".timing.json", complete["timings"][scene["id"]])
                require(record["inputs_sha256"] == complete["inputs_sha256"], "timing input link mismatch")
                key, metrics = validate_record(record, inputs, scene, suite["sample"])
                # Only an exact, source-audited set of option defaults may differ.
                # Full observed dictionaries remain in each raw inputs/record.
                if delta_keys:
                    key["pack_options"] = {k: v for k, v in key["pack_options"].items()
                                           if k not in delta_keys}
                records = by_scene[scene["id"]]
                if stock:
                    # Across arms only the pack identity, preset and pass contract may differ.
                    # Within an arm everything must repeat, including the first run's label set.
                    same_arm = [r for r in records if r["arm"] == run["arm"]]
                    if same_arm:
                        require(key == same_arm[0]["conditions"],
                                f"{scene['id']}: unlike scene/preset/dimensions/backend/inputs within arm {run['arm']}")
                        require(metrics.keys() == same_arm[0]["metrics"].keys(),
                                f"{scene['id']}: pass set changed across arm {run['arm']} runs")
                    if records:
                        require(common_conditions(key) == common_conditions(records[0]["conditions"]),
                                f"{scene['id']}: unlike scene/dimensions/backend/inputs across stock and pack arms")
                elif records:
                    require(key == records[0]["conditions"], f"{scene['id']}: unlike scene/preset/dimensions/backend/inputs")
                    require(metrics.keys() == records[0]["metrics"].keys(), f"{scene['id']}: pass set changed across runs")
                start, end = (datetime.fromisoformat(record[k]) for k in ("started_at", "finished_at"))
                first_start = start if first_start is None else min(first_start, start)
                last_end = end if last_end is None else max(last_end, end)
                records.append({"arm": run["arm"], "round": run["round"], "conditions": key, "metrics": metrics,
                                "raw_record": f"{label}/{scene['id']}.timing.json",
                                "raw_sha256": complete["timings"][scene["id"]],
                                "samples": {k: len(record["benchmark"][k]) for k in ("frame_ms", "cpu_ms", "gpu_ms")}})
            require(previous_end is None or first_start > previous_end, "runs overlap or were reordered")
            previous_end = last_end
        except (KeyError, TypeError, ValueError, OSError) as error:
            raise Invalid(f"{label}: {error}") from error
    rows, arm_rows, label_sets = [], [], {"A": {}, "B": {}}
    for scene_id, records in by_scene.items():
        if stock:
            first = {arm: next(r for r in records if r["arm"] == arm) for arm in ("A", "B")}
            for arm in ("A", "B"):
                label_sets[arm][scene_id] = sorted(set(first[arm]["metrics"]) - set(WHOLE_FRAME))
            # Pass rows are reported per arm and never differenced.
            for metric in sorted(set(label_sets["A"][scene_id]) | set(label_sets["B"][scene_id])):
                arm_rows.append({"scene": scene_id, "metric": metric, **{
                    f"{arm}_ms": interval([r["metrics"][metric] for r in records if r["arm"] == arm])
                    if metric in first[arm]["metrics"] else None for arm in ("A", "B")}})
        paired = WHOLE_FRAME if stock else sorted(records[0]["metrics"])
        for metric in paired:
            arms = {arm: [r["metrics"][metric] for r in records if r["arm"] == arm] for arm in ("A", "B")}
            deltas = []
            for group in range(suite["rounds"]):
                # Each balanced four-run block is the pairing unit; frames are not independent replicates.
                a, b = (statistics.mean(r["metrics"][metric] for r in records
                                        if r["round"] == group and r["arm"] == arm) for arm in ("A", "B"))
                deltas.append(b - a)
            rows.append({"scene": scene_id, "metric": metric, "A_ms": interval(arms["A"]),
                         "B_ms": interval(arms["B"]), "paired_delta_ms": interval(deltas)})
    summary = {"schema": 1, "kind": "sunsun-native-timing-summary", "bench_format": FORMAT,
               "reducer_sha256": digest(Path(__file__)),
               "evidence": suite["evidence"], "packs": identities, "profile": suite["profile"],
               "rounds": suite["rounds"], "rows": rows, "runs": by_scene,
               "option_delta": delta}
    if stock:
        summary.update(stock_arm=stock, pack_contract=contract, arm_pass_rows=arm_rows, label_sets=label_sets)
    return summary


def markdown(summary):
    def cell(value):
        return f"{value['median']:.3f} [{value['min']:.3f}, {value['max']:.3f}]"
    def escape(value):
        return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    lines = ["# Native pack timing", ""]
    if summary["evidence"] == "synthetic-fixture":
        lines += ["**Synthetic fixture — no measured performance evidence.**", ""]
    stock = summary.get("stock_arm")
    lines += [f"Preset: {summary['profile']}{' (B only; A has no pack)' if stock else ''}. "
              f"{summary['rounds']} balanced ABBA/BAAB rounds; "
              f"{summary['rounds'] * 2} independent client runs per {'arm' if stock else 'pack'} and scene.", ""]
    for arm, pack in sorted(summary["packs"].items()):
        if pack is None:
            lines.append(f"- {arm}: stock Horizon, no shader pack (empty `pickedShaderPack`, empty `shaderpacks/`, "
                         "admission `{kind: none, name: null}`).")
        else:
            lines.append(f"- {arm}: {escape(pack['version'])}; pack `{pack['sha256']}`; source `{pack['source_revision']}`.")
    if stock:
        lines += ["", "This is a stock-relative comparison on the same signed client. Paired Δ covers only the "
                  "whole-frame metrics (GPU-span p50, elapsed-frame p50 and p95, CPU-work p50). The arms time "
                  "different pass sets, so renderer and pack rows are listed per arm below and are never "
                  "differenced. Pass timers are on in both arms and B times more passes, which biases Δ upward."]
    if summary.get("option_delta") is not None:
        lines += ["", "This is an explicitly declared option-isolation experiment, not an identical-settings pack rewrite. "
                  + ", ".join(f"A {key}=true, B {key}=false"
                              for key in declared_isolation_keys(summary['option_delta']))
                  + "; every other declared default and observed scene/control must match. The per-arm full option "
                  "dictionaries remain in raw inputs and receipts.", ""]
    first = next(iter(summary["runs"].values()))[0]["conditions"]
    renderer = first["observed"]["renderer"]
    lines += ["", f"Horizon `{first['horizon']['source_revision']}`; {escape(renderer['gpu'])}; "
              f"{escape(renderer['driver'])}; {renderer['backend']}; "
              f"{renderer['size'][0]}×{renderer['size'][1]} SDR; {first['backend']}; offscreen.", "",
              f"The gallery uses --offscreen: no swapchain presents occur, and the native queue is paced at "
              f"at most two frames ahead. Reported present_mode={escape(renderer['present_mode'])} is a configuration "
              "field, not an active presentation path here.", "",
              "All values are milliseconds. Arm cells are the median across run estimates [minimum, maximum]. "
              "Δ is B − A, paired by each four-run block's two-run mean, then summarized across blocks. "
              "These are observed repeat ranges, not confidence intervals.", "",
              "Elapsed-frame p50/p95, CPU-work p50 and GPU-span p50 are recomputed from the preserved native arrays "
              "with nearest-rank quantiles. GPU arrays are asynchronous and are not aligned to elapsed or CPU arrays. "
              "Renderer/pack rows are the endpoint rolling medians of up to 15 recent timestamp observations; "
              "the pinned format supplies neither per-pass raw arrays nor counts/ages. Do not sum these rows.", "",
              "The GPU span is the native marker interval, excluding earlier upload/preparation commands and later "
              "presentation work. Timer namespaces are not causal ownership: native shadows are renderer-timer rows, "
              "and pack material/vertex work shares world draws. Pass instrumentation can split the sky into its own pass. "
              "These independent streams cannot partition present/sync waits or assign the cross-client gap.", "",
              "Pass timing instrumentation is on. Elapsed frames include waits and are not physical display "
              "presentation measurements. No presented FPS, causal improvement, thermal correction or visual equivalence is inferred.", "",
              "| Scene | Metric | A ms [range] | B ms [range] | Paired Δ ms [range] |",
              "| --- | --- | ---: | ---: | ---: |"]
    for row in summary["rows"]:
        lines.append(f"| {escape(row['scene'])} | {escape(row['metric'])} | {cell(row['A_ms'])} | "
                     f"{cell(row['B_ms'])} | {cell(row['paired_delta_ms'])} |")
    if stock:
        lines += ["", "Per-arm pass rows (rolling medians; not differenced, not additive; — means the arm has no "
                  "such timed pass):", "", "| Scene | Metric | A ms [range] | B ms [range] |", "| --- | --- | ---: | ---: |"]
        for row in summary["arm_pass_rows"]:
            lines.append(f"| {escape(row['scene'])} | {escape(row['metric'])} | "
                         f"{cell(row['A_ms']) if row['A_ms'] else '—'} | {cell(row['B_ms']) if row['B_ms'] else '—'} |")
    lines += ["", "Raw records, observations, identities and sample counts remain in the private suite. "
              "summary.json lists their paths and hashes without replacing or trimming them.", ""]
    return "\n".join(lines)


def make_plan(args):
    pins = {arm: read_json(getattr(args, "pin_" + arm.lower())) for arm in ("A", "B")}
    for pin in pins.values():
        check_pin(pin)
    stock = stock_arm(pins)
    contracts = {}
    for arm, pin in pins.items():
        archive = getattr(args, "pack_" + arm.lower(), None)
        if is_stock(pin):
            require(archive is None, f"stock arm {arm} takes no pack archive")
        else:
            require(archive is not None, f"arm {arm} requires --pack-{arm.lower()}")
            contracts[arm] = pack_contract(archive, pin, args.profile)
    require(pins["A"]["horizon"] == pins["B"]["horizon"], "A/B must use the same signed Nightly binaries")
    delta_name = getattr(args, "allow_option_delta", None)
    option_delta = None
    if stock:
        # B alone carries the preset and pass contract; A is the same client with no pack.
        require(delta_name is None, "option isolation compares two packs; a stock arm has no options")
    else:
        require(pins["A"]["pack"]["sha256"] != pins["B"]["pack"]["sha256"], "A and B are identical archives")
    if not stock and delta_name is None:
        require(contracts["A"] == contracts["B"], "A/B presets/default options or timed stage labels differ")
    elif not stock:
        option_delta = {"id": delta_name, "A": 1, "B": 0}
        delta_keys = declared_isolation_keys(option_delta)
        require(contracts["A"]["expected_shader_passes"] == contracts["B"]["expected_shader_passes"],
                "pass graph differs in option isolation")
        aopts, bopts = contracts["A"]["pack_options"], contracts["B"]["pack_options"]
        require(all(aopts.get(key) == 1 and bopts.get(key) == 0 for key in delta_keys),
                "option isolation requires enabled A and disabled B")
        require({k: v for k, v in aopts.items() if k not in delta_keys}
                == {k: v for k, v in bopts.items() if k not in delta_keys},
                "unapproved additional option difference")
    cfg = read_json(args.catalogue)
    require(cfg["schema"] == 1 and cfg["capture_size"] == [1920, 1080], "use the 1080p gallery catalogue")
    scenes = [scene for scene in cfg["scenes"] if scene["id"] in args.scene]
    require(len(args.scene) == len(set(args.scene)) and set(args.scene) == {s["id"] for s in scenes}, "unknown or duplicate scene")
    require(not any(scene.get("lod_chunks", 0) for scene in scenes),
            "this pin cannot verify timing activation with screenshot-sequence while LOD is enabled; select near scenes")
    require(3 <= args.warmup <= 300 and 1 <= args.seconds <= 60, "warmup must be 3..300 s; sample must be 1..60 s")
    for name, expected in pins["A"]["horizon"]["binaries"].items():
        require(digest(args.bin / name) == expected, f"binary pin mismatch: {name}")
    suite = {"schema": 1, "kind": "sunsun-native-timing-suite", "bench_format": FORMAT,
             "evidence": "measurement", "complete": False, "pins": pins, "profile": args.profile,
             "render_mode": "offscreen", "option_delta": option_delta,
             "catalogue_sha256": digest(args.catalogue), "resource_sha256": resource_digest(args.resources),
             "scenes": scenes, "rounds": args.rounds, "sample": {"warmup_seconds": args.warmup, "seconds": args.seconds},
             "runs": schedule(args.rounds)}
    if stock:
        suite.update(stock_arm=stock, pack_contract=contracts["B"])
    return suite


def interrupted(_signum, _frame):
    # A terminal or control-group stop can reach parent and child together. A
    # second notification must not interrupt the first notification's cleanup.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise KeyboardInterrupt


def run_capture(command):
    """Let the gallery supervisor clean up its own display/client on interruption."""
    process = subprocess.Popen(command, start_new_session=True)
    try:
        code = process.wait()
        if code:
            raise subprocess.CalledProcessError(code, command)
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise


def capture_command(args, suite, run, root):
    """One gallery capture; a stock arm differs only by having no pack archive or preset."""
    arm = run["arm"].lower()
    pack = [] if is_stock(suite["pins"][run["arm"]]) else ["--pack", str(getattr(args, "pack_" + arm).resolve())]
    profile = [] if is_stock(suite["pins"][run["arm"]]) else ["--profile", args.profile]
    command = [sys.executable, str(HERE / "gallery-capture.py"), *pack,
               "--pin", str(getattr(args, "pin_" + arm).resolve()),
               "--bin", str(args.bin.resolve()), "--resources", str(args.resources.resolve()),
               "--catalogue", str(args.catalogue.resolve()), *profile,
               "--output", str(root / run["directory"]), "--backend", "gamescope",
               "--deadline", args.deadline.isoformat(), "--idle-guard", str(args.idle_guard.resolve()),
               "--timing-warmup", str(args.warmup), "--timing-seconds", str(args.seconds)]
    for scene in suite["scenes"]:
        command += ["--scene", scene["id"], "--timing-scene", scene["id"]]
    return command


def run_suite(args, suite):
    require(args.deadline is not None and args.deadline.utcoffset() is not None, "run requires a timezone-aware idle-slot deadline")
    require((args.deadline - datetime.now(timezone.utc)).total_seconds() >= 40, "deadline too close to start")
    root = private_output(args.output)
    write_json(root / "suite.json", suite)
    try:
        for run in suite["runs"]:
            command = capture_command(args, suite, run, root)
            print(f"{run['directory']}: {', '.join(s['id'] for s in suite['scenes'])}", flush=True)
            try:
                run_capture(command)
            except subprocess.CalledProcessError as error:
                try:
                    cleanup = read_json(root / run["directory"] / "cleanup.json")
                except (OSError, ValueError):
                    cleanup = None
                if isinstance(cleanup, dict) and cleanup.get("completed") is False:
                    reason = cleanup.get("reason")
                    if isinstance(reason, str) and reason:
                        raise Invalid(f"{run['directory']}: {reason}") from error
                raise
            for name in ("complete", "cleanup"):
                run[name + "_sha256"] = digest(root / run["directory"] / (name + ".json"))
            write_json(root / "suite.json", suite)
        suite["complete"] = True
        write_json(root / "suite.json", suite)
        # A completed process schedule still must pass matching and evidence checks.
        reduce_to(root, root / "reduced")
    except BaseException as error:
        suite["failure"] = str(error) or "interrupted"
        write_json(root / "suite.json", suite)
        raise


def reduce_to(root, output):
    output = private_output(output)
    try:
        summary = reduce_suite(root)
    except (Invalid, KeyError, TypeError, ValueError, OSError) as error:
        write_json(output / "diagnostics.json", {"valid": False, "reason": str(error),
                   "action": "Retain all raw records. Correct the reported mismatch and start a new complete interleaved suite."})
        raise Invalid(f"{error}; diagnostics: {output / 'diagnostics.json'}") from error
    write_json(output / "summary.json", summary)
    (output / "timing.md").write_text(markdown(summary))
    print(output / "timing.md")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "run"):
        command = commands.add_parser(name, help="read-only preflight" if name == "plan" else "run gallery capture in a confirmed idle slot")
        for arm in ("a", "b"):
            # Only A may be stock Horizon, whose pin names no pack; omit --pack-a for it.
            command.add_argument("--pack-" + arm, type=Path, required=arm == "b")
            command.add_argument("--pin-" + arm, type=Path, required=True)
        command.add_argument("--bin", type=Path, required=True)
        command.add_argument("--resources", type=Path, required=True)
        command.add_argument("--catalogue", type=Path, default=HERE / "gallery-scenes.json")
        command.add_argument("--scene", action="append", required=True)
        command.add_argument("--profile", choices=PROFILES, default="Medium")
        command.add_argument("--allow-option-delta", choices=["local_haze", "clouds", "water_reflections", "weather_detail", "light_medium_pair"],
                             help="Private one-bit option isolation; A ON, B OFF")
        command.add_argument("--rounds", type=int, default=3)
        command.add_argument("--warmup", type=float, default=10)
        command.add_argument("--seconds", type=float, default=8)
        if name == "run":
            command.add_argument("--output", type=Path, required=True)
            command.add_argument("--deadline", type=datetime.fromisoformat, required=True)
            command.add_argument("--idle-guard", type=Path, default=Path.home() / ".local/bin/edge-input-idle")
    command = commands.add_parser("reduce", help="strict deterministic local reduction; no renderer launched")
    command.add_argument("suite", type=Path)
    command.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "reduce":
        reduce_to(args.suite.resolve(), args.output)
    else:
        suite = make_plan(args)
        if args.command == "plan":
            print(json.dumps(suite, indent=2, sort_keys=True, allow_nan=False))
        else:
            signal.signal(signal.SIGTERM, interrupted)
            signal.signal(signal.SIGINT, interrupted)
            run_suite(args, suite)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, Invalid, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError, release.Refused) as error:
        sys.exit(f"REFUSED: {error or 'interrupted'}")
