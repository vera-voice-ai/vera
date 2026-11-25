"""Offline: telling the channels apart, the size budget, and the once-only injection. Run: python3 -m unittest discover -s tests"""
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("vera_context", ROOT / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ContextTest(unittest.TestCase):
    def setUp(self):
        self.mod = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.data = pathlib.Path(self.tmp.name)
        (self.data / "main-session.json").write_text(json.dumps({"session_id": "local-mac"}))
        (self.data / "phone-session.json").write_text(json.dumps({"session_id": "local-phone"}))
        os.environ["VERA_DATA"] = str(self.data)

    def tearDown(self):
        os.environ.pop("VERA_DATA", None)
        self.tmp.cleanup()

    def test_channels(self):
        c = self.mod.channel
        self.assertEqual(c(client="vera-phone"), "phone")
        self.assertEqual(c(client="vera-mac"), "mac")
        self.assertEqual(c(platform="telegram"), "telegram")
        self.assertEqual(c(session_id="local-phone"), "phone")
        self.assertEqual(c(session_id="local-mac"), "mac")
        self.assertIsNone(c(session_id="cron-1", platform="cron"))

    def test_fits_hermes_budget(self):
        for ch in [None, "mac", "phone", "telegram"]:
            self.assertLessEqual(len(self.mod.text(ch)), 4000, ch)

    def test_section_marks_session(self):
        out = self.mod.section({"session_id": "local-new", "platform": "tui", "client": "vera-phone"})
        self.assertIn("«iPhone»: приложение", out)
        self.assertIsNone(self.mod.pre_llm_call(session_id="local-new", platform="tui"))

    def test_old_session_gets_it_once(self):
        first = self.mod.pre_llm_call(session_id="local-phone", platform="tui")
        self.assertIn("phone_route", first["context"])
        self.assertIsNone(self.mod.pre_llm_call(session_id="local-phone", platform="tui"))

    def test_changed_text_reaches_old_sessions_once(self):
        self.mod.section({"session_id": "local-mac", "platform": "tui", "client": "vera-mac"})
        self.assertIsNone(self.mod.pre_llm_call(session_id="local-mac", platform="tui"))
        self.mod.CHANNELS["mac"] += "\nНовое: инструмент mac_example."
        again = self.mod.pre_llm_call(session_id="local-mac", platform="tui")
        self.assertIn("mac_example", again["context"])
        self.assertIn("обновилась", again["context"])
        self.assertIsNone(self.mod.pre_llm_call(session_id="local-mac", platform="tui"))

    def test_owner_name_comes_from_local_settings(self):
        self.assertNotIn("Владельца зовут", self.mod.text("mac", self.data))
        (self.data / "local.json").write_text(json.dumps({"owner": "Мария"}, ensure_ascii=False), encoding="utf-8")
        self.assertIn("Владельца зовут Мария.", self.mod.text("mac", self.data))
        self.assertIn("Владельца зовут Мария.", self.mod.text(None, self.data))

    def test_ids_only_file_from_before_counts_as_older_text(self):
        (self.data / "vera-context-seen.json").write_text(json.dumps(["local-mac"]))
        self.assertIn("mac_browser", self.mod.pre_llm_call(session_id="local-mac", platform="tui")["context"])
        self.assertIsNone(self.mod.pre_llm_call(session_id="local-mac", platform="tui"))

    def test_other_sessions_get_nothing_injected(self):
        self.assertIsNone(self.mod.pre_llm_call(session_id="cron-1", platform="cron"))

    def test_without_data_never_raises(self):
        os.environ.pop("VERA_DATA")
        self.assertIn("Вера 0.3", self.mod.section({"session_id": "x"}))
        self.assertIsNone(self.mod.pre_llm_call(session_id="x", platform="cli"))


if __name__ == "__main__":
    unittest.main()
