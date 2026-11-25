"""Offline test: hooks with Hermes-shaped kwargs → sanitized JSONL. Run: python3 -m unittest discover -s tests"""
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("vera_pulse", ROOT / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class PulseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["VERA_PULSE_DIR"] = self.tmp.name
        self.mod = load()

    def tearDown(self):
        os.environ.pop("VERA_PULSE_DIR", None)
        self.tmp.cleanup()

    def lines(self):
        files = list(pathlib.Path(self.tmp.name).glob("*.jsonl"))
        self.assertEqual(len(files), 1)
        return [json.loads(l) for l in files[0].read_text().splitlines()]

    def test_tool_call_is_sanitized(self):
        secret = "sk-SECRET-should-not-leak"
        self.mod.pre_tool_call(tool_name="terminal", args={"command": f"echo {secret}"}, session_id="s1",
                               tool_call_id="c1", turn_id="t1", task_id="x", middleware_trace=[])
        self.mod.post_tool_call(tool_name="terminal", args={"command": secret}, result=secret, session_id="s1",
                                tool_call_id="c1", duration_ms=42, status="success", error_type=None)
        raw = "".join(pathlib.Path(self.tmp.name).glob("*.jsonl").__next__().read_text())
        self.assertNotIn(secret, raw)
        start, end = self.lines()
        self.assertEqual(start["kind"], "tool.start")
        self.assertEqual(end["kind"], "tool.end")
        self.assertEqual(end["name"], "terminal")
        self.assertEqual(end["call_id"], "c1")
        self.assertEqual(end["duration_ms"], 42)

    def test_llm_end_counts_tokens_and_seconds(self):
        self.mod.post_api_request(session_id="s1", api_request_id="r1", model="m", provider="p",
                                  api_duration=1.5, usage={"prompt_tokens": 100, "completion_tokens": 20},
                                  assistant_message={"content": "private answer"}, finish_reason="stop")
        (e,) = self.lines()
        self.assertEqual((e["kind"], e["duration_ms"], e["tokens_in"], e["tokens_out"]), ("llm.end", 1500.0, 100, 20))
        self.assertNotIn("private answer", json.dumps(e))

    def test_event_is_broadcast_live_as_the_same_dict(self):
        sent = []
        pkg = types.ModuleType("hermes_cli")
        events = types.ModuleType("hermes_cli.plugin_events")
        events.broadcast_plugin_event = lambda plugin, event, payload=None: sent.append((plugin, event, payload))
        saved = {k: sys.modules.get(k) for k in ("hermes_cli", "hermes_cli.plugin_events")}
        sys.modules["hermes_cli"], sys.modules["hermes_cli.plugin_events"] = pkg, events
        try:
            self.mod.post_api_request(session_id="s1", api_request_id="r1", model="m", provider="p",
                                      api_duration=0.5, usage={"prompt_tokens": 7, "completion_tokens": 3})
        finally:
            for k, v in saved.items():
                if v is None:
                    sys.modules.pop(k, None)
                else:
                    sys.modules[k] = v
        (e,) = self.lines()
        self.assertEqual(len(sent), 1)
        plugin, event, payload = sent[0]
        self.assertEqual((plugin, event), ("vera-pulse", "event"))
        self.assertEqual(payload, e)

    def test_broadcast_without_hermes_never_raises(self):
        saved = {k: sys.modules.get(k) for k in ("hermes_cli.plugin_events",)}
        sys.modules["hermes_cli.plugin_events"] = None  # import fails, as outside Hermes
        try:
            self.assertIsNone(self.mod.post_api_request(session_id="s1", api_request_id="r2", model="m"))
        finally:
            for k, v in saved.items():
                if v is None:
                    sys.modules.pop(k, None)
                else:
                    sys.modules[k] = v
        self.assertEqual(len(self.lines()), 1)

    def test_default_dir_follows_hermes_home(self):
        os.environ.pop("VERA_PULSE_DIR")
        os.environ["HERMES_HOME"] = self.tmp.name
        try:
            self.assertEqual(self.mod.pulse_dir(), pathlib.Path(self.tmp.name) / "vera-pulse")
        finally:
            os.environ.pop("HERMES_HOME")
            os.environ["VERA_PULSE_DIR"] = self.tmp.name

    def test_hook_error_never_raises(self):
        self.assertIsNone(self.mod.post_api_request(api_duration="bad", usage=object()))

    def test_register_wires_every_hook_and_rpc(self):
        got = {}

        class Ctx:
            def register_hook(self, name, fn):
                got[name] = fn

            def register_rpc(self, name, fn):
                got["rpc:" + name] = fn

        self.mod.register(Ctx())
        manifest = (ROOT / "plugin.yaml").read_text()
        for name in self.mod.HOOKS:
            self.assertIn(name, got)
            self.assertIn(f"- {name}", manifest)
        self.assertIn("rpc:recent", got)

    def test_lock_lists_exactly_these_hooks(self):
        """The lock lists the pulse's hooks plus those other Vera plugins declare (plugin.yaml provides_hooks)."""
        lock = json.loads((ROOT.parents[1] / "hermes.lock.json").read_text())
        others = set()
        for manifest in ROOT.parent.glob("*/plugin.yaml"):
            if manifest.parent == ROOT:
                continue
            for line in manifest.read_text().splitlines():
                if line.startswith("provides_hooks:"):
                    others |= {h.strip() for h in line.split(":", 1)[1].strip(" []").split(",") if h.strip()}
        self.assertEqual(set(lock["hooks_used"]), set(self.mod.HOOKS) | others)


if __name__ == "__main__":
    unittest.main()
