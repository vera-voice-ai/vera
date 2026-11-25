"""Offline: the request/answer files and the state file, with a fake Vera answering. Run: python3 -m unittest discover -s tests"""
import importlib.util
import json
import pathlib
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("vera_phone", ROOT / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class PhoneTest(unittest.TestCase):
    def setUp(self):
        self.mod = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.bridge = pathlib.Path(self.tmp.name) / "phone-bridge"

    def tearDown(self):
        self.tmp.cleanup()

    def fake_vera(self, ok=True, text="маршрут до «Лес» готов"):
        """Answers the first request the way Vera does: reads the command, writes results/<id>.json."""
        def run():
            commands = self.bridge / "commands"
            for _ in range(200):
                files = list(commands.glob("*.json")) if commands.exists() else []
                if files:
                    cmd = json.loads(files[0].read_text())
                    self.seen = cmd
                    files[0].unlink()
                    (self.bridge / "results").mkdir(parents=True, exist_ok=True)
                    (self.bridge / "results" / f"{cmd['id']}.json").write_text(json.dumps({"id": cmd["id"], "ok": ok, "text": text}))
                    return
                time.sleep(0.02)
        t = threading.Thread(target=run)
        t.start()
        return t

    def test_route_round_trip(self):
        t = self.fake_vera()
        r = self.mod.request("route", destination="Лес", start=True, bridge=self.bridge, wait=5)
        t.join()
        self.assertEqual(r, {"ok": True, "text": "маршрут до «Лес» готов"})
        self.assertEqual(self.seen["action"], "route")
        self.assertEqual(self.seen["destination"], "Лес")
        self.assertTrue(self.seen["start"])
        self.assertEqual(list((self.bridge / "results").iterdir()), [])

    def test_music_play_carries_the_query(self):
        t = self.fake_vera(text="Miyagi, 12 треков")
        r = self.mod.request("music.play", query="Miyagi", bridge=self.bridge, wait=5)
        t.join()
        self.assertTrue(r["ok"])
        self.assertEqual(self.seen["action"], "music.play")
        self.assertEqual(self.seen["query"], "Miyagi")

    def test_music_control_checks_the_action(self):
        self.assertFalse(json.loads(self.mod.handle_music_control({"action": "louder"}))["ok"])

    def test_no_answer_cleans_up(self):
        r = self.mod.request("stop", bridge=self.bridge, wait=0.3)
        self.assertFalse(r["ok"])
        self.assertEqual(list((self.bridge / "commands").glob("*.json")), [])

    def test_without_vera_data(self):
        self.assertFalse(self.mod.request("stop", wait=0.1)["ok"] if not self.mod.available() else False)

    def test_empty_destination(self):
        self.assertFalse(json.loads(self.mod.handle_route({"destination": "  "}))["ok"])

    def test_status_reads_state_and_arrival(self):
        self.bridge.mkdir(parents=True)
        (self.bridge / "nav.json").write_text(json.dumps({
            "phase": "guiding", "destination": "Лес", "remainingSeconds": 600, "remainingMeters": 8000,
            "address": None, "at": 1000.0}))
        s = self.mod.status(bridge=self.bridge, now=1030.0)
        self.assertTrue(s["ok"])
        self.assertEqual(s["phase"], "guiding")
        self.assertEqual(s["updated_seconds_ago"], 30)
        self.assertIn("arrival_local_time", s)
        self.assertNotIn("address", s)

    def test_status_without_state(self):
        self.assertFalse(self.mod.status(bridge=self.bridge)["ok"])


if __name__ == "__main__":
    unittest.main()
