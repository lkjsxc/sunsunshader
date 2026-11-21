import contextlib
from pathlib import Path
import shutil
import tempfile
import unittest

import post_ir
from release import PACK, Refused


COMPOSE = "shaders/compose.wgsl"
FOCUS = "shaders/focus.wgsl"
LENS = "shaders/lens.wgsl"
DISPLAY = "shaders/display.wgsl"
COMPAT = "shaders/compat.wgsl"
POST = "fn post(input: PostInput) -> vec4<f32> {"
TONEMAP = "fn tonemap(input: TonemapInput) -> vec3<f32> {"
INHERITED_MOTION = """        let previous_clip = frame.previous_view_projection * vec4<f32>(position + frame.camera_motion, 1.0);
        if previous_clip.w > 0.0 {
            let old_uv = vec2<f32>(previous_clip.x / previous_clip.w * 0.5 + 0.5,
                0.5 - previous_clip.y / previous_clip.w * 0.5);
            var motion = (uv - old_uv) * 0.30;
            let pixels = length(motion * frame.resolution);
            motion *= min(1.0, 12.0 / max(pixels, 0.01));
            for (var i = 1u; i <= 4u; i += 1u) {
                color += ss_picture_at(uv - motion * (f32(i) / 4.0));
            }
            color /= 5.0;
        }
"""


class PostContinuityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = Path(cls.enterClassContext(tempfile.TemporaryDirectory(prefix="sunsun-post-ir-")))
        cls.checker = post_ir.build()
        cls.receipt = post_ir.check(cls.checker, PACK)

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(dir=self.scratch) as scratch:
            candidate = Path(scratch) / "pack"
            shutil.copytree(PACK, candidate)
            yield candidate

    def edit(self, pack, file, before, after):
        path = pack / file
        old = path.read_text()
        self.assertEqual(old.count(before), 1, before)
        path.write_text(old.replace(before, after))

    def mutate(self, file, edit):
        with self.fixture() as pack:
            path = pack / file
            original = path.read_text()
            changed = edit(original)
            self.assertNotEqual(changed, original)
            path.write_text(changed)
            return post_ir.check(self.checker, pack)

    def insert_post(self, shader, helpers=""):
        return self.mutate(COMPOSE, lambda source: source.replace(POST, helpers + "\n" + POST + "\n" + shader))

    def insert_display(self, shader, helpers=""):
        return self.mutate(DISPLAY, lambda source: source.replace(TONEMAP, helpers + "\n" + TONEMAP + "\n" + shader))

    def test_uniform_and_geometric_gates(self):
        self.insert_post("""
    var color = input.color;
    if quality > 0u && frame.delta_time > 0.0 { color *= 0.9; }
    if !vignette && floor(input.uv.x * 2.0) > 0.0 { color *= 0.8; }
    if input.pixel.x > 1.0 && textureDimensions(previous).x > 0u { color *= 0.5; }
    if frame.resolution.x < 2.0 { return color; }
""")

    def test_boundary_and_budget_receipt(self):
        stages = self.receipt["stages"]
        self.assertEqual([stage["roots"] for stage in stages], [["post"], ["tonemap"]])
        self.assertEqual(
            [item["boundary"] for stage in stages for item in stage["proven_boundaries"]],
            ["compose: previous_clip.w = 0 and fade = 0 and 1 (finite stock camera envelope)",
             "focus: blur = 0 and 1", "lens: axis_mix = 0 and 1"])
        self.assertTrue(all(not stage["inherited_exceptions"] for stage in stages))
        self.assertTrue(all(stage["untainted_decisions"] > 0 for stage in stages))
        self.assertIn({"name": "ss_world_bound", "file": COMPAT}, stages[1]["functions_scanned"])
        budget = self.receipt["budget"]
        self.assertEqual([budget[key] for key in ("draw_passes", "compute_entries", "resources",
                                                 "plain_outputs", "target_sixteenths")], [5, 4, 7, 0, 10])
        self.assertEqual(budget["limits"]["draw_passes"], 12)
        air = next(stage for stage in budget["stages"] if stage["file"] == "shaders/air.wgsl")
        self.assertEqual((air["expressions"], air["texture_reads"]), (5655, 14))
        bindings = self.receipt["binding_checks"]["resolved_stages"]
        compose = next(stage for stage in bindings if stage["file"] == COMPOSE)
        names = {binding["name"] for binding in compose["bindings"]}
        self.assertTrue({"previous", "linear_sampler", "ss_bloom"} <= names)
        self.assertEqual(self.receipt["dependencies"], self.checker.dependencies)
        self.assertTrue(self.receipt["dependencies"]["locked_transitives"])

    def test_old_axis_select(self):
        def historical(source):
            start = source.index("        let band =")
            end = source.index("        color = mix(color, filtered", start)
            return source[:start] + """        let across = select(vec2<f32>(0.0, texel.y), vec2<f32>(texel.x, 0.0), horizontal > vertical);
        let filtered = (ss_lens_read(uv - across * 0.4) + ss_lens_read(uv + across * 0.4)) * 0.5;
""" + source[end:]

        with self.assertRaisesRegex(Refused, r"lens.wgsl.*unproved post choice 'select'"):
            self.mutate(LENS, historical)

    def test_step_and_old_focus_branch(self):
        with self.assertRaisesRegex(Refused, r"focus.wgsl.*unproved post choice 'if'"):
            self.mutate(FOCUS, lambda source: source.replace("if blur > 0.0", "if radius > 0.2"))
        with self.assertRaisesRegex(Refused, r"focus.wgsl.*unproved post choice 'step'"):
            self.mutate(FOCUS, lambda source: source.replace("return min(length(", "return step(0.2, min(length(")
                        .replace("frame.far);", "frame.far));"))

    def test_edited_endpoints_and_motion_body_are_refused(self):
        for stage, before, after in (
            (LENS, "0.0001", "0.0"),
            (LENS, "filtered = ss_lens_pair(uv, axis_y);", "filtered = ss_lens_pair(uv, axis_x);"),
            (FOCUS, "color = filtered;", "color = filtered * 0.5;"),
            (COMPOSE, "if fade > 0.0", "if previous_clip.w > 0.0"),
            (COMPOSE, "0.002 * previous_distance", "0.0"),
            (COMPOSE, "previous_clip.x / projection_w", "previous_clip.x / previous_clip.w"),
            (COMPOSE, "color = blurred;", "color = blurred * 0.5;"),
            (COMPOSE, "mix(color, blurred, fade)", "mix(color, blurred, 1.0 - fade)"),
        ):
            with self.subTest(stage=stage, before=before), self.assertRaisesRegex(
                    Refused, f"{stage}: .*fingerprint mismatch.*unproved post choice 'if'"):
                self.mutate(stage, lambda source: source.replace(before, after))

    def test_inherited_motion_refuses_directly(self):
        def historical(source):
            start = source.index("        let previous =")
            end = source.index("    }\n    return color;", start)
            return source[:start] + INHERITED_MOTION + source[end:]

        with self.assertRaisesRegex(Refused, r"compose.wgsl.*fingerprint mismatch.*unproved post choice 'if'"):
            self.mutate(COMPOSE, historical)

    def test_registered_function_cannot_be_bypassed(self):
        with self.assertRaisesRegex(Refused, r"missing post continuity boundary ss_focus"):
            self.mutate(COMPOSE, lambda source: source.replace(
                "ss_focus(input.uv, ss_moving_picture_at(input.uv, input.depth))",
                "ss_moving_picture_at(input.uv, input.depth)"))

    def test_image_data_cannot_shadow_uniform_gate(self):
        with self.assertRaisesRegex(Refused, r"compose.wgsl.*unproved post choice 'if'"):
            self.insert_post("let quality = input.depth; if quality > 0.2 { return input.color; }")
        self.insert_post("let quality = input.uv.x; if quality > 0.2 { return input.color; }")

    def test_shared_helper_and_unknown_calls(self):
        with self.assertRaisesRegex(Refused, r"compat.wgsl.*unproved post choice 'step'"):
            self.mutate(COMPAT, lambda source: source.replace(
                "return positive / max(peak, 1.0);", "return step(vec3<f32>(0.2), positive);"))
        with self.assertRaisesRegex(Refused, r"display.wgsl.*ss_unreviewed"):
            self.mutate(DISPLAY, lambda source: source.replace("ss_filmic(", "ss_unreviewed("))

    def test_comments_and_shifted_spans_do_not_hide_choices(self):
        receipt = self.mutate(COMPOSE, lambda source: "/* outer /* if false {} */ select */\n" + source)
        self.assertEqual(receipt["stages"][0]["proven_boundaries"][0]["fingerprint"],
                         self.receipt["stages"][0]["proven_boundaries"][0]["fingerprint"])
        with self.assertRaisesRegex(Refused, r"display.wgsl.*unproved post choice 'step'"):
            self.insert_display("// WGSL line separator follows\u2028let edge = step(vec3f(0.2), input.color);\n"
                                "if quality == 0u { return edge; }")

    def test_discrete_image_coordinates_and_resolved_sampler(self):
        with self.assertRaisesRegex(Refused, r"compose.wgsl.*unproved post choice 'textureLoad'"):
            self.insert_post("let tap = textureLoad(previous, vec2i(input.color.xy), 0);\n"
                             "if quality == 0u { return tap; }")
        # Naga resolves both the actual binding and the forwarded sampler.
        helper = """
fn tap_at(tex: texture_2d<f32>, smp: sampler, uv: vec2f) -> vec4f {
    return textureSampleLevel(tex, smp, uv, 0.0);
}
"""
        source = "if quality == 0u { return tap_at(previous, SAMPLER, input.color.xy); }"
        self.insert_post(source.replace("SAMPLER", "linear_sampler"), helper)
        with self.assertRaisesRegex(Refused, r"compose.wgsl.*unproved post choice 'textureSample'"):
            self.insert_post(source.replace("SAMPLER", "nearest_sampler"), helper)

    def test_select_comparison_and_uniform_coordinate_image_load(self):
        for reason, code in (
            ("select", "let choice = select(vec4f(0.0), input.color, input.color.x > 0.2);"
                       "if quality == 0u { return choice; }"),
            ("comparison|select|image-dependent cast", "let mask = f32(input.color.x > input.color.y);"
                                                       "if quality == 0u { return vec4f(mask); }"),
            ("if", "let v = textureLoad(previous, vec2i(0), 0).r;"
                   "if v > 0.0 { return input.color; }"),
        ):
            with self.subTest(reason=reason), self.assertRaisesRegex(
                    Refused, rf"compose.wgsl.*unproved post choice '(?:{reason})'"):
                self.insert_post(code)

    def test_struct_fields_local_stores_and_call_contexts(self):
        helper = """
struct Packet { geometry: f32, radiance: f32 }
fn choose(value: f32) -> f32 { if value > 0.2 { return 0.5; } return 1.0; }
fn inject(value: ptr<function, Packet>, light: f32) { (*value).radiance = light; }
"""
        body = """
    var packet = Packet(input.uv.x, 0.0);
    inject(&packet, input.color.x);
    let scale = choose(packet.geometry);
    if quality == 0u { return input.color * scale; }
"""
        self.insert_post(body, helper)
        with self.assertRaisesRegex(Refused, r"compose.wgsl.*unproved post choice 'if'.*in choose"):
            self.insert_post(body.replace("input.color * scale", "input.color * scale * choose(packet.radiance)"),
                             helper)

    def test_array_element_store_preserves_image_taint(self):
        helper = "struct Packet { geometry: f32, radiance: f32 }"
        with self.assertRaisesRegex(Refused, r"compose.wgsl.*unproved post choice 'if'"):
            self.insert_post("""
    var packets: array<Packet, 2>;
    packets[0] = Packet(input.uv.x, input.color.x);
    if packets[0].radiance > 0.2 { return input.color; }
""", helper)

    def test_discrete_control_flow_and_dynamic_index(self):
        for reason, code in (
            ("switch", "switch u32(input.depth) { case 0u: { return input.color; } default: {} }"),
            ("break if", "loop { continuing { break if input.depth > 0.2; } }"),
            ("dynamic access index", "let values = array(input.color, vec4f(0.0));"
                                     "if quality == 0u { return values[u32(input.depth)]; }"),
        ):
            with self.subTest(reason=reason), self.assertRaisesRegex(
                    Refused, rf"compose.wgsl.*unproved post choice '{reason}'"):
                self.insert_post(code)

    def test_extra_plain_binding_shifts_prelude_without_changing_proofs(self):
        with self.fixture() as pack:
            compose = '[[post]]\nfile = "shaders/compose.wgsl"'
            fixture = ('[[post]]\nfile = "shaders/fixture.wgsl"\n'
                       'output = "fixture_output"\nscale = 0.25\n\n')
            self.edit(pack, "horizon-shaders.toml", compose, fixture + compose)
            (pack / "shaders/fixture.wgsl").write_text(
                POST + " return input.color; }\n")
            receipt = post_ir.check(self.checker, pack)
        self.assertEqual(receipt["budget"]["plain_outputs"], 1)
        self.assertEqual(receipt["budget"]["target_sixteenths"], 11)
        self.assertEqual([stage["proven_boundaries"] for stage in receipt["stages"]],
                         [stage["proven_boundaries"] for stage in self.receipt["stages"]])

    def test_kept_storage_and_duplicate_post_files(self):
        with self.fixture() as pack:
            self.edit(pack, "horizon-shaders.toml", 'reads = ["ss_bloom"]',
                      'reads = ["ss_bloom", "ss_world_light"]')
            self.edit(pack, COMPOSE, POST,
                      POST + "\n    if ss_world_light[0].x != 0u { return input.color; }")
            with self.assertRaisesRegex(Refused, r"compose.wgsl.*unproved post choice 'if'"):
                post_ir.check(self.checker, pack)

        with self.fixture() as pack:
            self.edit(pack, "horizon-shaders.toml", 'file = "shaders/bloom_seed.wgsl"',
                      'file = "shaders/air.wgsl"')
            (pack / "shaders/bloom_seed.wgsl").unlink()
            with self.assertRaisesRegex(Refused, r"post files must be unique"):
                post_ir.check(self.checker, pack)


if __name__ == "__main__":
    unittest.main()
