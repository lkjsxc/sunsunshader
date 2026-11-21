"""Small local fixtures only: no client, GPU, browser, account or network."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

import gallery_timing as timing

HERE = Path(__file__).resolve().parent
RAW = timing.read_json(HERE / "fixtures/native-bench-5ef7734.json")


def load_tool(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


capture = load_tool("gallery_capture", "gallery-capture.py")
pin_tool = load_tool("gallery_pin", "gallery-pin.py")


def scaled_raw(factor):
    result = copy.deepcopy(RAW)
    for key in ("frame_ms", "cpu_ms", "gpu_ms"):
        result[key] = [value * factor for value in result[key]]
    result["seconds"] *= factor
    for key in ("avg_fps", "low_1pct_fps", "low_01pct_fps"):
        result[key] /= factor
    for key in ("p50_ms", "p95_ms", "p99_ms", "max_ms"):
        result[key] *= factor
    for key in ("cpu", "gpu", "gpu_passes", "shader_passes"):
        result[key] = {name: value * factor for name, value in result[key].items()}
    return result


# The stock raw format: renderer rows only, and no shader_passes key at all.
STOCK_GPU_PASSES = {"Animated sprites": .0025, "World": 1.25, "World after culling": .5}
PACK_STAGING = [".horizon-options/", ".horizon-options/sunsunshader.txt", "sunsunshader.hshader"]


def stock_raw(factor):
    result = scaled_raw(factor)
    del result["shader_passes"]
    result["gpu_passes"] = {name: value * factor for name, value in STOCK_GPU_PASSES.items()}
    return result


def stock_pin(pin):
    return {"schema": 1, "arm": "stock", "horizon": pin["horizon"], "pack": None}


def build_suite(root, *, isolated=False, isolated_key="local_haze", stock=False):
    """Representative receipt/admission shapes, explicitly synthetic numbers.

    With stock=True, A is stock Horizon under the stock-arm contract and B is a pinned pack.
    """
    keys = ("local_haze", "clouds") if isolated_key == "light_medium_pair" else (isolated_key,)
    cfg = timing.read_json(HERE / "gallery-scenes.json")
    scenes = [cfg["scenes"][0], cfg["scenes"][3]]
    pins = {arm: timing.read_json(HERE / "gallery-inputs.json") for arm in ("A", "B")}
    for arm, char in (("A", "1"), ("B", "2")):
        pins[arm]["pack"]["sha256"] = char * 64
        pins[arm]["pack"]["source_revision"] = char * 40
    if stock:
        pins["A"] = stock_pin(pins["A"])
    suite = {"schema": 1, "kind": "sunsun-native-timing-suite", "bench_format": timing.FORMAT,
             "evidence": "synthetic-fixture", "complete": True, "pins": pins, "profile": "Medium",
             "render_mode": "offscreen",
             "catalogue_sha256": "3" * 64, "resource_sha256": "4" * 64,
             "scenes": scenes, "rounds": 2, "sample": {"warmup_seconds": 3, "seconds": 1},
             "runs": timing.schedule(2)}
    if isolated:
        suite["option_delta"] = {"id": isolated_key, "A": 1, "B": 0}
    if stock:
        suite["stock_arm"] = "A"
        suite["pack_contract"] = {"pack_options": {"quality": 1, "shadows": 1},
                                  "expected_shader_passes": sorted(RAW["shader_passes"])}
    counts = {"A": 0, "B": 0}
    factors = {"A": [1, 1.02, .98, 1.04], "B": [1.1, 1.08, 1.12, 1.1]}
    for run in suite["runs"]:
        directory = root / run["directory"]
        directory.mkdir()
        arm = run["arm"]
        factor = factors[arm][counts[arm]]
        counts[arm] += 1
        is_stock = stock and arm == "A"
        pack_options = None if is_stock else {"quality": 1, "shadows": 1}
        if isolated:
            for key in keys:
                pack_options[key] = 1 if arm == "A" else 0
        inputs = {"schema": 2, "kind": "sunsun-gallery-inputs", "pack": pins[arm]["pack"],
                  "horizon": pins[arm]["horizon"], "resource_sha256": "4" * 64, "catalogue_sha256": "3" * 64,
                  "capture_tool_sha256": "5" * 64, "timing_tool_sha256": "6" * 64,
                  "world": cfg["world"], "seed": cfg["seed"], "profile": "Medium",
                  "pack_options": pack_options, "size": [1920, 1080],
                  "format": "SDR", "backend": "gamescope", "render_mode": "offscreen", "fov": 70, "full_detail_chunks": 10,
                  "graphics": timing.GRAPHICS, "machine": {"host": "synthetic-host", "system": "Linux",
                      "kernel": "fixture", "architecture": "x86_64", "cpu_affinity": [0, 1, 2, 3]},
                  "expected_shader_passes": sorted(RAW["shader_passes"])}
        if is_stock:
            inputs.update(arm="stock", staging=copy.deepcopy(timing.STOCK_STAGING), profile=None,
                          expected_shader_passes=None)
        timing.write_json(directory / "inputs.json", inputs)
        input_hash = timing.digest(directory / "inputs.json")
        complete = {"scenes": [s["id"] for s in scenes], "inputs_sha256": input_hash, "timings": {}}
        for index, scene in enumerate(scenes):
            started = datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=run["index"] * 30 + index * 5)
            renderer = {"gpu": "SYNTHETIC adapter", "vendor": "amd", "driver": "SYNTHETIC driver",
                        "device_type": "integrated", "backend": "Vulkan", "size": [1920, 1080],
                        "present_mode": "Mailbox", "resolution_scale": 100, "dynamic_resolution": False,
                        "msaa_requested": 1, "msaa_samples": 1, "gpu_culling_mode": "off", "gpu_culling": False,
                        "packed_layout": True, "resident_sections": 100}
            installed = f"/tmp/synthetic-{run['directory']}/game/shaderpacks/sunsunshader.hshader"
            snapshot = {"world_game_time": 80 * (index + 1),
                        "state": {"world": cfg["world"], "dimension": "minecraft:overworld", "gamemode": "spectator",
                                  "paused": False, "player": {"position": scene["position"], "yaw": scene["look"][0],
                                  "pitch": scene["look"][1], "effects": []}, "time": {"day_time": scene["time"]},
                                  "weather": {"raining": False, "thundering": False}},
                        "status": {"screen": "playing", "renderer": renderer, "render_distance": 10,
                                   "lod": {"distance": 0, "resident_quads": 0, "levels": []}},
                        "options": {"options": {key: {"value": value} for key, value in {
                            "fov": 70, "maxFps": 260, "enableVsync": False, "bobView": False,
                            "vignette": False, "gamma": .5, "inactivityFpsLimit": "minimized"}.items()}},
                        "installed_pack": installed, "installed_pack_sha256": None,
                        "pack_options": copy.deepcopy(pack_options), "blocks": [],
                        "admission": {"pack": {"kind": "native", "name": installed}}}
            if is_stock:
                snapshot.update(installed_pack=None, admission={"pack": copy.deepcopy(timing.STOCK_ADMISSION)})
            else:
                snapshot["installed_pack_sha256"] = pins[arm]["pack"]["sha256"]
            condition = {"load_average": [.1, .1, .1], "power_online": {}, "cpu_governors": {},
                         "temperatures_millidegrees": {}}
            record = {"schema": 1, "kind": "sunsun-native-timing", "bench_format": timing.FORMAT,
                      "inputs_sha256": input_hash, "scene": scene, "sample": suite["sample"],
                      "reset": {"ok": True, "gpu_passes": False}, "reset_wait_frames": 2,
                      "enable": {"ok": True, "gpu_passes": True, "detail": False},
                      "disable": {"ok": True, "gpu_passes": False, "detail": False},
                      "before": snapshot, "after": copy.deepcopy(snapshot), "conditions_before": condition,
                      "conditions_after": copy.deepcopy(condition), "started_at": started.isoformat(),
                      "finished_at": (started + timedelta(seconds=2)).isoformat(),
                      "benchmark": stock_raw(factor) if is_stock else scaled_raw(factor)}
            timing.write_json(directory / f"{scene['id']}.timing.json", record)
            complete["timings"][scene["id"]] = timing.digest(directory / f"{scene['id']}.timing.json")
        timing.write_json(directory / "complete.json", complete)
        cleanup = {"completed": True, "temporary_game_removed": True}
        if stock:
            listing = timing.STOCK_STAGING["shaderpacks"] if is_stock else PACK_STAGING
            cleanup["staging"] = [{"full_detail_chunks": 10, "lod_chunks": 0, "launch": list(listing),
                                   "quit": list(listing)}]
        timing.write_json(directory / "cleanup.json", cleanup)
        run["complete_sha256"] = timing.digest(directory / "complete.json")
        run["cleanup_sha256"] = timing.digest(directory / "cleanup.json")
    timing.write_json(root / "suite.json", suite)
    return suite


def rewrite_record(root, mutate, run_index=0):
    suite = timing.read_json(root / "suite.json")
    run = suite["runs"][run_index]
    directory = root / run["directory"]
    name = suite["scenes"][0]["id"]
    path = directory / (name + ".timing.json")
    record = timing.read_json(path)
    mutate(record)
    timing.write_json(path, record)
    complete = timing.read_json(directory / "complete.json")
    complete["timings"][name] = timing.digest(path)
    timing.write_json(directory / "complete.json", complete)
    run["complete_sha256"] = timing.digest(directory / "complete.json")
    timing.write_json(root / "suite.json", suite)


def rewrite_arm(root, arm, *, inputs=None, record=None, cleanup=None):
    """Apply one consistent change to every run of an arm and re-chain its hashes."""
    suite = timing.read_json(root / "suite.json")
    for run in suite["runs"]:
        if run["arm"] != arm:
            continue
        directory = root / run["directory"]
        complete = timing.read_json(directory / "complete.json")
        if inputs:
            value = timing.read_json(directory / "inputs.json")
            inputs(value)
            timing.write_json(directory / "inputs.json", value)
            complete["inputs_sha256"] = timing.digest(directory / "inputs.json")
        for scene in suite["scenes"]:
            path = directory / (scene["id"] + ".timing.json")
            value = timing.read_json(path)
            value["inputs_sha256"] = complete["inputs_sha256"]
            if record:
                record(value)
            timing.write_json(path, value)
            complete["timings"][scene["id"]] = timing.digest(path)
        timing.write_json(directory / "complete.json", complete)
        run["complete_sha256"] = timing.digest(directory / "complete.json")
        if cleanup:
            value = timing.read_json(directory / "cleanup.json")
            cleanup(value)
            timing.write_json(directory / "cleanup.json", value)
            run["cleanup_sha256"] = timing.digest(directory / "cleanup.json")
    timing.write_json(root / "suite.json", suite)


def rewrite_suite(root, mutate):
    suite = timing.read_json(root / "suite.json")
    mutate(suite)
    timing.write_json(root / "suite.json", suite)


class NativeFormatTests(unittest.TestCase):
    def test_native_nearest_rank_and_asynchronous_gpu_samples(self):
        metrics = timing.native_metrics(RAW, RAW["shader_passes"])
        self.assertEqual(metrics["elapsed frame p50"], 30)
        self.assertEqual(metrics["CPU work p50"], 4)
        self.assertEqual(metrics["GPU span p50"], 9)
        self.assertEqual(len(RAW["frame_ms"]), 32)
        self.assertEqual(len(RAW["gpu_ms"]), 3)
        self.assertEqual(timing.quantile([10, 20, 30, 40], .5), 20)

    def test_missing_maps_passes_and_raw_are_not_filled(self):
        for field in ("gpu_passes", "shader_passes", "frame_ms", "cpu_ms", "gpu_ms"):
            with self.subTest(field=field):
                raw = copy.deepcopy(RAW)
                del raw[field]
                with self.assertRaises((timing.Invalid, KeyError)):
                    timing.native_metrics(raw, RAW["shader_passes"])
        for field, name in (("shader_passes", "Air"), ("gpu_passes", "World after copy")):
            raw = copy.deepcopy(RAW)
            del raw[field][name]
            with self.assertRaisesRegex(timing.Invalid, "missing"):
                timing.native_metrics(raw, RAW["shader_passes"])

    def test_malformed_samples_and_inconsistent_native_summary(self):
        for bad in (float("nan"), float("inf"), -1, True, "1"):
            raw = copy.deepcopy(RAW)
            raw["frame_ms"][0] = bad
            with self.subTest(bad=bad), self.assertRaises(timing.Invalid):
                timing.native_metrics(raw, RAW["shader_passes"])
        for field, value in (("frames", 0), ("frames", 33), ("seconds", 2), ("p50_ms", 99)):
            raw = copy.deepcopy(RAW)
            raw[field] = value
            with self.subTest(field=field), self.assertRaises(timing.Invalid):
                timing.native_metrics(raw, RAW["shader_passes"])

    def test_stock_metrics_admit_only_renderer_rows_without_pack_labels(self):
        metrics = timing.native_metrics(stock_raw(1), None, stock=True)
        self.assertEqual(set(metrics), set(timing.WHOLE_FRAME) | {"renderer: " + name for name in STOCK_GPU_PASSES})
        empty = stock_raw(1)
        empty["shader_passes"] = {}
        self.assertEqual(timing.native_metrics(empty, None, stock=True), metrics)
        # The stock/pack declaration and the expected pass contract must agree in both directions.
        for raw, expected, stock in ((stock_raw(1), RAW["shader_passes"], True), (RAW, None, False)):
            with self.assertRaisesRegex(timing.Invalid, "disagree"):
                timing.native_metrics(raw, expected, stock=stock)

    def test_json_rejects_duplicate_keys_and_nonfinite_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"
            for text in ('{"World":1,"World":2}', '{"time":NaN}', '{"time":Infinity}'):
                path.write_text(text)
                with self.assertRaises(timing.Invalid):
                    timing.read_json(path)


class SuiteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.suite = build_suite(self.root)

    def test_balanced_schedule(self):
        self.assertEqual("".join(run["arm"] for run in timing.schedule(3)), "ABBABAABABBA")
        with self.assertRaises(timing.Invalid):
            timing.schedule(1)

    def test_deterministic_reduction_pairing_and_preservation(self):
        before = {path: timing.digest(path) for path in self.root.rglob("*") if path.is_file()}
        first, second = timing.reduce_suite(self.root), timing.reduce_suite(self.root)
        self.assertEqual(first, second)
        row = next(row for row in first["rows"] if row["scene"] == "night-lantern" and row["metric"] == "elapsed frame p50")
        self.assertAlmostEqual(row["A_ms"]["median"], 30.3)
        self.assertAlmostEqual(row["B_ms"]["median"], 33.0)
        self.assertAlmostEqual(row["paired_delta_ms"]["median"], 2.7)
        self.assertAlmostEqual(row["paired_delta_ms"]["min"], 2.4)
        self.assertAlmostEqual(row["paired_delta_ms"]["max"], 3.0)
        text = timing.markdown(first)
        self.assertIn("Synthetic fixture", text)
        self.assertIn("not confidence intervals", text)
        self.assertIn("not physical display", text)
        self.assertIn("up to 15", text)
        self.assertIn("no swapchain presents", text)
        self.assertEqual(before, {path: timing.digest(path) for path in before})

    def test_pack_against_pack_keeps_every_paired_row(self):
        summary = timing.reduce_suite(self.root)
        self.assertNotIn("stock_arm", summary)
        self.assertNotIn("arm_pass_rows", summary)
        metrics = {row["metric"] for row in summary["rows"] if row["scene"] == "night-lantern"}
        self.assertEqual(metrics, set(timing.native_metrics(RAW, RAW["shader_passes"])))
        self.assertIn("pack: Air", metrics)

    def test_declared_local_haze_isolation_accepts_only_one_bit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            suite = build_suite(root, isolated=True)
            summary = timing.reduce_suite(root)
            self.assertEqual(summary["option_delta"], {"id": "local_haze", "A": 1, "B": 0})
            self.assertIn("A local_haze=true, B local_haze=false", timing.markdown(summary))
            for invalid in ({"id": "local_haze", "A": 0, "B": 1},
                            {"id": "shadows", "A": 1, "B": 0}, None):
                modified = copy.deepcopy(suite)
                modified["option_delta"] = invalid
                timing.write_json(root / "suite.json", modified)
                with self.assertRaises(timing.Invalid):
                    timing.reduce_suite(root)
            timing.write_json(root / "suite.json", suite)
            rewrite_record(root, lambda record: record["before"]["pack_options"].update(local_haze=2))
            with self.assertRaises(timing.Invalid):
                timing.reduce_suite(root)

    def test_declared_cloud_isolation_preserves_all_other_controls(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            suite = build_suite(root, isolated=True, isolated_key="clouds")
            summary = timing.reduce_suite(root)
            self.assertEqual(summary["option_delta"], {"id": "clouds", "A": 1, "B": 0})
            self.assertIn("A clouds=true, B clouds=false", timing.markdown(summary))
            # Unapproved isolated settings cannot pass by merely changing the
            # declaration; actual per-arm defaults remain independently checked.
            suite["option_delta"] = {"id": "local_haze", "A": 1, "B": 0}
            timing.write_json(root / "suite.json", suite)
            with self.assertRaises(timing.Invalid):
                timing.reduce_suite(root)

    def test_declared_water_and_weather_isolation(self):
        for option in ("water_reflections", "weather_detail"):
            with self.subTest(option=option), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                build_suite(root, isolated=True, isolated_key=option)
                summary = timing.reduce_suite(root)
                self.assertEqual(summary["option_delta"], {"id": option, "A": 1, "B": 0})
                self.assertIn("A " + option + "=true, B " + option + "=false", timing.markdown(summary))

    def test_declared_light_medium_pair_and_undeclared_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            suite = build_suite(root, isolated=True, isolated_key="light_medium_pair")
            summary = timing.reduce_suite(root)
            self.assertEqual(summary["option_delta"], {"id": "light_medium_pair", "A": 1, "B": 0})
            message = timing.markdown(summary)
            self.assertIn("A local_haze=true, B local_haze=false", message)
            self.assertIn("A clouds=true, B clouds=false", message)
            rewrite_record(root, lambda r: r["after"]["pack_options"].update(clouds=1), run_index=1)
            with self.assertRaises(timing.Invalid):
                timing.reduce_suite(root)
            # A forged single-bit declaration cannot hide the second difference.
            suite["option_delta"] = {"id": "local_haze", "A": 1, "B": 0}
            timing.write_json(root / "suite.json", suite)
            with self.assertRaises(timing.Invalid):
                timing.reduce_suite(root)

    def test_presentation_path_is_required_and_not_mixed(self):
        directory = self.root / "001-A"
        inputs = timing.read_json(directory / "inputs.json")
        record = timing.read_json(directory / "night-lantern.timing.json")
        for mode in (None, "presented"):
            inputs["render_mode"] = mode
            with self.assertRaisesRegex(timing.Invalid, "presentation path"):
                timing.validate_record(record, inputs, self.suite["scenes"][0], self.suite["sample"])

    def test_incomplete_reordered_or_partial_suite_refused(self):
        for change in (lambda s: s.update(complete=False), lambda s: s["runs"].pop(),
                       lambda s: s["runs"].reverse()):
            suite = copy.deepcopy(self.suite)
            change(suite)
            timing.write_json(self.root / "suite.json", suite)
            with self.assertRaises(timing.Invalid):
                timing.reduce_suite(self.root)

    def test_clock_device_profile_and_pose_mismatches(self):
        changes = [lambda r: r["after"].update(world_game_time=81),
                   lambda r: r["after"]["status"]["renderer"].update(size=[960, 540]),
                   lambda r: r["after"]["status"]["renderer"].update(driver="other driver"),
                   lambda r: r["after"]["status"]["renderer"].update(backend="OpenGL"),
                   lambda r: r["before"]["pack_options"].update(quality=2),
                   lambda r: r["after"]["state"]["player"].update(position=[0, 0, 0]),
                   lambda r: r["after"]["state"]["time"].update(day_time=6000),
                   lambda r: r["after"]["options"]["options"]["fov"].update(value=90),
                   lambda r: r["after"]["options"]["options"]["inactivityFpsLimit"].update(value="afk")]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                directory = self.root / f"case-{index}"
                directory.mkdir()
                build_suite(directory)
                rewrite_record(directory, change)
                with self.assertRaises(timing.Invalid):
                    timing.reduce_suite(directory)

    def test_like_for_like_pass_sets_required(self):
        rewrite_record(self.root, lambda r: r["benchmark"]["gpu_passes"].update(HUD=.1), run_index=1)
        with self.assertRaisesRegex(timing.Invalid, "pass set changed"):
            timing.reduce_suite(self.root)

    def test_missing_metadata_and_native_activation_refused(self):
        rewrite_record(self.root, lambda r: r["after"]["admission"].update(pack={"kind": "none"}))
        with self.assertRaisesRegex(timing.Invalid, "activation"):
            timing.reduce_suite(self.root)

    def test_raw_hash_change_is_detected(self):
        path = self.root / "001-A/night-lantern.timing.json"
        path.write_text(path.read_text() + " ")
        with self.assertRaisesRegex(timing.Invalid, "hash mismatch"):
            timing.reduce_suite(self.root)

    def test_invalid_cli_produces_diagnostics_and_no_timing_table(self):
        rewrite_record(self.root, lambda r: r.pop("enable"))
        output = self.root / "rejected"
        result = subprocess.run([sys.executable, str(HERE / "gallery_timing.py"), "reduce", str(self.root),
                                 "--output", str(output)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((output / "timing.md").exists())
        self.assertFalse(timing.read_json(output / "diagnostics.json")["valid"])

    def test_missing_completed_cleanup_refused(self):
        (self.root / "001-A/cleanup.json").unlink()
        with self.assertRaises(timing.Invalid):
            timing.reduce_suite(self.root)


class StockArmTests(unittest.TestCase):
    """The stock arm contract: synthetic, pre-GPU refusals only."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "suite"
        self.root.mkdir()
        self.suite = build_suite(self.root, stock=True)

    def fresh(self, name):
        root = Path(self.tmp.name) / name
        root.mkdir()
        build_suite(root, stock=True)
        return root

    def test_stock_suite_pairs_whole_frame_metrics_and_reports_passes_per_arm(self):
        before = {path: timing.digest(path) for path in self.root.rglob("*") if path.is_file()}
        summary = timing.reduce_suite(self.root)
        self.assertEqual(summary, timing.reduce_suite(self.root))
        self.assertEqual(summary["stock_arm"], "A")
        self.assertIsNone(summary["packs"]["A"])
        self.assertEqual(summary["packs"]["B"], self.suite["pins"]["B"]["pack"])
        self.assertEqual(summary["pack_contract"], self.suite["pack_contract"])
        for scene in self.suite["scenes"]:
            self.assertEqual([row["metric"] for row in summary["rows"] if row["scene"] == scene["id"]],
                             list(timing.WHOLE_FRAME))
        row = next(row for row in summary["rows"] if row["scene"] == "night-lantern" and row["metric"] == "elapsed frame p50")
        self.assertAlmostEqual(row["A_ms"]["median"], 30.3)
        self.assertAlmostEqual(row["B_ms"]["median"], 33.0)
        self.assertAlmostEqual(row["paired_delta_ms"]["median"], 2.7)
        # No per-pass delta exists anywhere: pass rows are per arm, with None where an arm lacks the label.
        self.assertTrue(summary["arm_pass_rows"])
        for pass_row in summary["arm_pass_rows"]:
            self.assertEqual(set(pass_row), {"scene", "metric", "A_ms", "B_ms"})
        self.assertFalse({row["metric"] for row in summary["rows"]} - set(timing.WHOLE_FRAME))
        rows = {(r["scene"], r["metric"]): r for r in summary["arm_pass_rows"]}
        self.assertIsNone(rows["night-lantern", "renderer: World after culling"]["B_ms"])
        self.assertIsNone(rows["night-lantern", "pack: Air"]["A_ms"])
        self.assertIsNotNone(rows["night-lantern", "renderer: World"]["A_ms"])
        self.assertIsNotNone(rows["night-lantern", "renderer: World"]["B_ms"])
        self.assertEqual(summary["label_sets"]["A"]["night-lantern"],
                         sorted("renderer: " + name for name in STOCK_GPU_PASSES))
        text = timing.markdown(summary)
        self.assertIn("stock Horizon, no shader pack", text)
        self.assertIn("never differenced", text)
        self.assertIn("Synthetic fixture", text)
        for line in text.splitlines():
            if "| pack: " in line or "| renderer: " in line:
                self.assertEqual(line.count("|"), 5, line)  # Scene, metric, A, B: no Δ column.
        self.assertEqual(before, {path: timing.digest(path) for path in before})

    def test_stock_record_carrying_a_pack_label_is_refused(self):
        changes = [lambda r: r["benchmark"]["gpu_passes"].update({"Native shader pack shadow": .4}),
                   lambda r: r["benchmark"]["gpu_passes"].update({"Native shader pack translucent shadow": .1}),
                   lambda r: r["benchmark"]["gpu_passes"].update({"World after copy": .25}),
                   lambda r: r["benchmark"]["gpu_passes"].update({"Flatten": .1}),
                   lambda r: r["benchmark"]["gpu_passes"].update({"Flatten phase 2": .1}),
                   lambda r: r["benchmark"].update(shader_passes={"Air": .175}),
                   lambda r: r["benchmark"].update(shader_passes=None),
                   lambda r: r["benchmark"]["gpu_passes"].pop("World")]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                root = self.fresh(f"label-{index}")
                rewrite_record(root, change)
                with self.assertRaisesRegex(timing.Invalid, "pack|missing renderer"):
                    timing.reduce_suite(root)

    def test_stock_admission_must_be_exactly_no_pack(self):
        native = {"kind": "native", "name": "/tmp/game/shaderpacks/sunsunshader.hshader"}
        changes = [lambda r: r["before"]["admission"].update(pack=native),
                   lambda r: r["after"]["admission"].update(pack=native),
                   lambda r: r["after"]["admission"].update(pack={"kind": "none"}),
                   lambda r: r["after"]["admission"].update(pack={"kind": "none", "name": ""}),
                   lambda r: r["after"]["admission"].update(pack={"kind": "native", "name": None})]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                root = self.fresh(f"admission-{index}")
                rewrite_record(root, change)
                with self.assertRaisesRegex(timing.Invalid, "stock activation"):
                    timing.reduce_suite(root)

    def test_stock_record_with_an_installed_pack_is_refused(self):
        changes = [lambda r: r["before"].update(installed_pack="/tmp/game/shaderpacks/sunsunshader.hshader"),
                   lambda r: r["after"].update(installed_pack_sha256="2" * 64),
                   lambda r: r["after"].update(pack_options={"quality": 1}),
                   lambda r: r["before"].update(pack_options={})]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                root = self.fresh(f"installed-{index}")
                rewrite_record(root, change)
                with self.assertRaisesRegex(timing.Invalid, "installed pack"):
                    timing.reduce_suite(root)

    def test_stock_against_stock_and_stock_b_are_refused(self):
        pin = self.suite["pins"]["A"]
        pack = self.suite["pins"]["B"]
        for pins in ({"A": pin, "B": pin}, {"A": pack, "B": pin}):
            with self.subTest(pins=sorted(arm for arm, value in pins.items() if value is pin)):
                with self.assertRaisesRegex(timing.Invalid, "exactly one stock arm"):
                    timing.stock_arm(pins)
        rewrite_suite(self.root, lambda s: s["pins"].update(B=copy.deepcopy(pin)))
        with self.assertRaisesRegex(timing.Invalid, "exactly one stock arm"):
            timing.reduce_suite(self.root)

    def test_drift_in_a_key_that_was_not_dropped_is_refused(self):
        def driver(record):
            for when in ("before", "after"):
                record[when]["status"]["renderer"]["driver"] = "other driver"
        changes = [("B", {"record": driver}),
                   ("A", {"inputs": lambda i: i.update(timing_tool_sha256="7" * 64)}),
                   ("A", {"inputs": lambda i: i.update(capture_tool_sha256="8" * 64)}),
                   ("B", {"inputs": lambda i: i.update(fov=90), "record": lambda r: [
                       r[when]["options"]["options"]["fov"].update(value=90) for when in ("before", "after")]}),
                   ("A", {"inputs": lambda i: i["machine"].update(host="other-host")}),
                   ("A", {"record": lambda r: [r[when].update(world_game_time=r[when]["world_game_time"] + 1)
                                               for when in ("before", "after")]})]
        for index, (arm, change) in enumerate(changes):
            with self.subTest(index=index):
                root = self.fresh(f"drift-{index}")
                rewrite_arm(root, arm, **change)
                with self.assertRaisesRegex(timing.Invalid, "across stock and pack arms"):
                    timing.reduce_suite(root)
        # The same consistent drift inside one arm is still refused when it reaches only part of that arm.
        root = self.fresh("drift-within")
        rewrite_record(root, driver, run_index=3)
        with self.assertRaisesRegex(timing.Invalid, "within arm A"):
            timing.reduce_suite(root)

    def test_first_stock_run_fixes_the_label_set(self):
        rewrite_record(self.root, lambda r: r["benchmark"]["gpu_passes"].update(HUD=.1), run_index=3)
        with self.assertRaisesRegex(timing.Invalid, "pass set changed across arm A"):
            timing.reduce_suite(self.root)

    def test_stock_staging_declaration_and_pack_contract_are_required(self):
        cases = [("cleanup-quit", lambda root: rewrite_arm(
                      root, "A", cleanup=lambda c: c["staging"][0].update(quit=[".horizon-options/"]))),
                 ("cleanup-launch", lambda root: rewrite_arm(
                      root, "A", cleanup=lambda c: c["staging"][0].update(launch=["sunsunshader.hshader"]))),
                 ("cleanup-missing", lambda root: rewrite_arm(root, "A", cleanup=lambda c: c.pop("staging"))),
                 ("cleanup-empty", lambda root: rewrite_arm(root, "A", cleanup=lambda c: c.update(staging=[]))),
                 ("inputs-picked", lambda root: rewrite_arm(
                      root, "A", inputs=lambda i: i["staging"].update(picked_shader_pack="horizon:sunsunshader"))),
                 ("inputs-profile", lambda root: rewrite_arm(root, "A", inputs=lambda i: i.update(profile="Medium"))),
                 ("inputs-pack", lambda root: rewrite_arm(
                      root, "A", inputs=lambda i: i.update(pack=self.suite["pins"]["B"]["pack"]))),
                 ("inputs-undeclared", lambda root: rewrite_arm(root, "A", inputs=lambda i: i.pop("arm"))),
                 ("contract", lambda root: rewrite_suite(
                      root, lambda s: s["pack_contract"]["pack_options"].update(shadows=0))),
                 ("contract-missing", lambda root: rewrite_suite(root, lambda s: s.pop("pack_contract"))),
                 ("undeclared", lambda root: rewrite_suite(root, lambda s: s.pop("stock_arm"))),
                 ("declared-b", lambda root: rewrite_suite(root, lambda s: s.update(stock_arm="B"))),
                 ("delta", lambda root: rewrite_suite(
                      root, lambda s: s.update(option_delta={"id": "local_haze", "A": 1, "B": 0})))]
        for name, change in cases:
            with self.subTest(name=name):
                root = self.fresh(name)
                change(root)
                with self.assertRaises(timing.Invalid):
                    timing.reduce_suite(root)
        # A pack-against-pack suite cannot claim a stock arm either.
        root = Path(self.tmp.name) / "pack-declared"
        root.mkdir()
        build_suite(root)
        rewrite_suite(root, lambda s: s.update(stock_arm="A"))
        with self.assertRaisesRegex(timing.Invalid, "declared stock arm"):
            timing.reduce_suite(root)

    def test_pin_shapes(self):
        pin = self.suite["pins"]["A"]
        timing.check_pin(pin)
        self.assertTrue(timing.is_stock(pin))
        self.assertEqual(pin_tool.stock_pin(pin["horizon"]), pin)
        bad = [dict(pin, arm=None), dict(pin, arm="pack"), dict(pin, extra=1),
               dict(pin, pack=self.suite["pins"]["B"]["pack"]), dict(pin, schema=2),
               {"schema": 1, "horizon": pin["horizon"], "pack": None},
               dict(pin, horizon=dict(pin["horizon"], archive_sha256="x"))]
        for index, value in enumerate(bad):
            with self.subTest(index=index), self.assertRaises((timing.Invalid, KeyError, TypeError)):
                timing.check_pin(value)


class StockPlanTests(unittest.TestCase):
    """make_plan admits exactly one explicit stock A with no archive; no renderer or GPU is used."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / "bin").mkdir()
        (root / "resources").mkdir()
        (root / "resources/resource.bin").write_bytes(b"synthetic resource")
        pack = timing.read_json(HERE / "gallery-inputs.json")
        for name in ("horizon-client", "horizon-ctl"):
            (root / "bin" / name).write_bytes(name.encode())
            pack["horizon"]["binaries"][name] = timing.digest(root / "bin" / name)
        other = copy.deepcopy(pack)
        other["pack"]["sha256"] = "2" * 64
        self.pins = {"stock": stock_pin(pack), "pack": pack, "other": other}
        for name, value in self.pins.items():
            timing.write_json(root / f"{name}.json", value)
        (root / "A.hshader").write_bytes(b"A")
        (root / "B.hshader").write_bytes(b"B")
        self.root = root
        self.contract = {"pack_options": {"quality": 0, "shadows": 1}, "expected_shader_passes": ["Air"]}
        patcher = patch.object(timing, "pack_contract", lambda archive, pin, profile: copy.deepcopy(self.contract))
        patcher.start()
        self.addCleanup(patcher.stop)

    def args(self, pin_a="stock", pin_b="pack", pack_a=None, pack_b="B.hshader", **extra):
        value = dict(pin_a=self.root / f"{pin_a}.json", pin_b=self.root / f"{pin_b}.json",
                     pack_a=pack_a and self.root / pack_a, pack_b=pack_b and self.root / pack_b,
                     bin=self.root / "bin", resources=self.root / "resources",
                     catalogue=HERE / "gallery-scenes.json", scene=["night-lantern", "rain"], profile="Low",
                     rounds=3, warmup=10, seconds=8, allow_option_delta=None)
        value.update(extra)
        return SimpleNamespace(**value)

    def test_stock_a_plan(self):
        suite = timing.make_plan(self.args())
        self.assertEqual(suite["stock_arm"], "A")
        self.assertIsNone(suite["pins"]["A"]["pack"])
        self.assertEqual(suite["pack_contract"], self.contract)
        self.assertIsNone(suite["option_delta"])
        self.assertEqual("".join(run["arm"] for run in suite["runs"]), "ABBABAABABBA")

    def test_previous_pack_pairs_still_plan(self):
        suite = timing.make_plan(self.args(pin_a="other", pack_a="A.hshader"))
        self.assertNotIn("stock_arm", suite)
        self.assertNotIn("pack_contract", suite)
        with self.assertRaisesRegex(timing.Invalid, "identical archives"):
            timing.make_plan(self.args(pin_a="pack", pack_a="A.hshader"))

    def test_stock_plan_refusals(self):
        horizon = copy.deepcopy(self.pins["stock"])
        horizon["horizon"]["archive_sha256"] = "9" * 64
        timing.write_json(self.root / "stock-other-horizon.json", horizon)
        cases = {"stock with archive": self.args(pack_a="A.hshader"),
                 "stock B": self.args(pin_a="pack", pack_a="A.hshader", pin_b="stock", pack_b=None),
                 "stock against stock": self.args(pin_b="stock", pack_b=None),
                 "pack B without archive": self.args(pack_b=None),
                 "option delta": self.args(allow_option_delta="local_haze"),
                 "different client": self.args(pin_a="stock-other-horizon"),
                 "LOD scene": self.args(scene=["distant-lod"])}
        for name, args in cases.items():
            with self.subTest(name=name), self.assertRaises(timing.Invalid):
                timing.make_plan(args)
        (self.root / "bin/horizon-ctl").write_bytes(b"changed")
        with self.assertRaisesRegex(timing.Invalid, "binary pin mismatch"):
            timing.make_plan(self.args())

    def test_stock_capture_command_differs_only_by_pack_and_preset(self):
        suite = timing.make_plan(self.args())
        args = self.args(deadline=datetime(2026, 1, 1, tzinfo=timezone.utc), idle_guard=self.root / "guard")
        a = timing.capture_command(args, suite, suite["runs"][0], self.root)
        b = timing.capture_command(args, suite, suite["runs"][1], self.root)
        self.assertNotIn("--pack", a)
        self.assertNotIn("--profile", a)
        self.assertEqual(b[b.index("--pack") + 1], str(self.root / "B.hshader"))
        self.assertEqual(b[b.index("--profile") + 1], "Low")
        for flag in ("--pack", "--profile"):
            index = b.index(flag)
            del b[index:index + 2]
        differing = [a[i] for i in range(len(a)) if a[i] != b[i]]
        self.assertEqual(len(a), len(b))
        self.assertEqual(differing, [str(self.root / "stock.json"), str(self.root / "001-A")])
        self.assertEqual(a.count("--timing-scene"), 2)


class CaptureTests(unittest.TestCase):
    def test_input_watch_must_confirm_after_the_renderer_exits(self):
        for finish_status in (0, 1):
            with self.subTest(finish_status=finish_status), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "complete.json").write_text("{}")
                args = SimpleNamespace(backend="gamescope", idle_guard=root / "guard", output=root,
                                       deadline=datetime.now(timezone.utc) + timedelta(minutes=5))
                renderer = SimpleNamespace(poll=lambda: 0, returncode=0)
                # Refusal is delivered only after the supervisor observes renderer exit.
                script = ("import sys; sys.stdout.buffer.write(b'R'); sys.stdout.flush(); "
                          "assert sys.stdin.buffer.read(1) == b'F'; "
                          "sys.exit(int(sys.argv[1]))")
                with subprocess.Popen([sys.executable, "-c", script, str(finish_status)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0) as guard:
                    with (patch.object(capture, "idle_guard", return_value=guard),
                          patch.object(capture.subprocess, "Popen", return_value=renderer),
                          patch.object(capture, "stop_group") as stop):
                        if finish_status:
                            with self.assertRaisesRegex(RuntimeError, "refused capture completion"):
                                capture.supervise(args, root, {}, 1920, 1080)
                        else:
                            capture.supervise(args, root, {}, 1920, 1080)
                        stop.assert_called_once_with(renderer)
                    self.assertEqual(guard.returncode, finish_status)

    def test_suite_retains_capture_refusal_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "suite"
            args = SimpleNamespace(output=root, deadline=datetime.now(timezone.utc) + timedelta(minutes=5))
            suite = {"complete": False, "runs": [{"directory": "001-A"}], "scenes": [{"id": "rain"}]}
            reason = "The CachyOS Wayland input watch refused capture completion"

            def refuse(command):
                stopped = root / "001-A"
                stopped.mkdir()
                timing.write_json(stopped / "cleanup.json", {"completed": False, "reason": reason})
                raise subprocess.CalledProcessError(1, command)

            with (patch.object(timing, "capture_command", return_value=["fixture"]),
                  patch.object(timing, "run_capture", side_effect=refuse)):
                with self.assertRaisesRegex(timing.Invalid, reason):
                    timing.run_suite(args, suite)
            result = timing.read_json(root / "suite.json")
            self.assertFalse(result["complete"])
            self.assertEqual(result["failure"], f"001-A: {reason}")

    def test_stock_staging_writes_the_same_graphics_lines_and_lists_hidden_entries(self):
        stock = capture.graphics_text(0, "").splitlines()
        pack = capture.graphics_text(0, "horizon:sunsunshader").splitlines()
        self.assertEqual(stock[:-1], pack[:-1])
        self.assertEqual((stock[-1], pack[-1]), ("pickedShaderPack:", "pickedShaderPack:horizon:sunsunshader"))
        self.assertEqual(capture.graphics_text(64, "").splitlines()[1], "lodDistance:64")
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "shaderpacks"
            self.assertIsNone(capture.shaderpack_listing(directory))
            directory.mkdir()
            self.assertEqual(capture.shaderpack_listing(directory), [])
            (directory / ".horizon-options").mkdir()
            (directory / ".horizon-options/sunsunshader.txt").write_text("quality=0\n")
            self.assertEqual(capture.shaderpack_listing(directory),
                             [".horizon-options/", ".horizon-options/sunsunshader.txt"])
            link = Path(tmp) / "link"
            link.symlink_to(directory)
            self.assertIsNone(capture.shaderpack_listing(link))

    def test_stock_capture_arguments_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pin = stock_pin(timing.read_json(HERE / "gallery-inputs.json"))
            timing.write_json(root / "stock.json", pin)
            timing.write_json(root / "bad.json", dict(pin, arm="none"))
            base = [sys.executable, str(HERE / "gallery-capture.py"), "--bin", str(root / "bin"),
                    "--resources", str(root / "resources"), "--output", str(root / "out"),
                    "--backend", "software", "--software-icd", str(root / "icd.json")]
            cases = {"takes no --pack": ["--pin", str(root / "stock.json"), "--pack", str(root / "x.hshader")],
                     "omit --profile": ["--pin", str(root / "stock.json"), "--profile", "Low"],
                     "no-pack activation proof": ["--pin", str(root / "stock.json"), "--scene", "distant-lod"],
                     "invalid stock arm pin": ["--pin", str(root / "bad.json")],
                     "pack pin requires --pack": ["--pin", str(HERE / "gallery-inputs.json")]}
            for message, extra in cases.items():
                with self.subTest(message=message):
                    result = subprocess.run(base + extra, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(message, result.stderr)
            self.assertFalse((root / "out").exists())

    def test_repeated_interrupts_finish_scoped_descendant_cleanup(self):
        # CPU-only stand-ins for the suite, supervisor and private display.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            supervisor = root / "supervisor.py"
            supervisor.write_text(
                "import importlib.util, os, signal, subprocess, sys, time\n"
                "from pathlib import Path\n"
                f"sys.path.insert(0, {str(HERE)!r})\n"
                "import gallery_timing as timing\n"
                f"spec=importlib.util.spec_from_file_location('capture', {str(HERE / 'gallery-capture.py')!r})\n"
                "capture=importlib.util.module_from_spec(spec); spec.loader.exec_module(capture)\n"
                "signal.signal(signal.SIGTERM, timing.interrupted)\n"
                "signal.signal(signal.SIGINT, timing.interrupted)\n"
                "child=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(20)'], start_new_session=True)\n"
                f"root=Path({str(root)!r})\n"
                "(root/'pids').write_text(str(os.getpid())+' '+str(child.pid))\n"
                "try:\n"
                "    while True: time.sleep(.05)\n"
                "finally:\n"
                "    (root/'cleaning').write_text('started')\n"
                "    time.sleep(.2)\n"
                "    capture.stop_group(child)\n"
                "    (root/'cleaned').write_text('done')\n")
            launcher = root / "launcher.py"
            launcher.write_text(
                "import signal, sys\n"
                f"sys.path.insert(0, {str(HERE)!r})\n"
                "import gallery_timing as timing\n"
                "signal.signal(signal.SIGTERM, timing.interrupted)\n"
                "signal.signal(signal.SIGINT, timing.interrupted)\n"
                f"timing.run_capture([sys.executable, {str(supervisor)!r}])\n")
            process = subprocess.Popen([sys.executable, str(launcher)], start_new_session=True,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            pids = []
            def wait_for(path):
                end = time.monotonic() + 5
                while not path.exists() and time.monotonic() < end:
                    time.sleep(.01)
                self.assertTrue(path.exists(), str(path))
            try:
                wait_for(root / "pids")
                pids = list(map(int, (root / "pids").read_text().split()))
                os.killpg(process.pid, signal.SIGINT)
                wait_for(root / "cleaning")
                # Model a second control-group notification during guard teardown.
                os.kill(process.pid, signal.SIGTERM)
                os.kill(pids[0], signal.SIGTERM)
                process.wait(timeout=5)
                self.assertTrue((root / "cleaned").exists())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pids[1], 0)
            finally:
                for pid in pids + [process.pid]:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.wait(timeout=5)

    def test_exact_frozen_steps_and_overshoot_refusal(self):
        calls = []
        values = iter((0, 0, 20, 40))
        def ctl(*words):
            calls.append(words)
            return {"game_time": next(values)} if words[0] == "simulation" else {"ok": True}
        capture.step_world(ctl, 40)
        self.assertIn(("command", "tick step 40"), calls)
        values = iter((0, 41))
        with self.assertRaisesRegex(RuntimeError, "exact requested"):
            capture.step_world(ctl, 40)

    def test_pin_receipt_clean_admission_is_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "synthetic.hshader"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("horizon-shaders.toml", 'id="sunsunshader"\nversion="fixture"\napi="0.2"\n')
            horizon = timing.release.nightly_pin()
            receipt = {"schema": 1, "kind": "sunsunshader-compatibility-check", "target": "nightly",
                       "horizon": horizon, "ordinary_game_admission": True, "pack_worktree_clean": True,
                       "pack_commit": "a" * 40, "archive": {"sha256": timing.digest(path), "bytes": path.stat().st_size},
                       "official_report": {"ok": True, "sha256": timing.digest(path), "stages": ["fixture"],
                                           "id": "sunsunshader", "version": "fixture"}}
            self.assertEqual(pin_tool.check_pack(path, receipt, horizon)["version"], "fixture")
            changes = [lambda r: r.update(ordinary_game_admission=False), lambda r: r.update(pack_worktree_clean=False),
                       lambda r: r["archive"].update(sha256="0" * 64), lambda r: r["official_report"].update(stages=[]),
                       lambda r: r.update(target="main"), lambda r: r.update(pack_commit="missing")]
            for change in changes:
                bad = copy.deepcopy(receipt)
                change(bad)
                with self.assertRaises(ValueError):
                    pin_tool.check_pack(path, bad, horizon)


if __name__ == "__main__":
    unittest.main()
