"""Offline: the RPC validates input and never raises. Run: python3 -m unittest discover -s tests"""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("vera_setup", ROOT / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class SetupTest(unittest.TestCase):
    def test_requires_provider_and_model(self):
        self.assertEqual(load().set_main_model({"provider": "x"})["ok"], False)

    def test_without_hermes_reports_instead_of_raising(self):
        r = load().set_main_model({"provider": "deepseek", "model": "deepseek-chat"})
        self.assertFalse(r["ok"])
        self.assertIn("error", r)

    def test_account_usage_without_hermes_reports_instead_of_raising(self):
        r = load().account_usage()
        self.assertFalse(r["ok"])
        self.assertIn("error", r)

    def test_usage_wire_keeps_only_percents_and_resets(self):
        import datetime as dt
        from types import SimpleNamespace as NS
        snap = NS(provider="opencode-go", plan=None, details=(), unavailable_reason=None, raw={"secret": "x"},
                  windows=(NS(label="Rolling window", used_percent=23.4, reset_at=dt.datetime(2026, 11, 22, 18, tzinfo=dt.timezone.utc), scope="account"),
                           NS(label="Weekly", used_percent=None, reset_at=None, scope="account")))
        w = load()._usage_wire(snap)
        self.assertEqual(w["windows"][0], {"label": "Rolling window", "used_percent": 23.4,
                                           "reset_at": "2026-11-22T18:00:00+00:00", "scope": "account"})
        self.assertIsNone(w["windows"][1]["used_percent"])
        self.assertNotIn("raw", w)

    def test_home_channels_without_hermes_reports_instead_of_raising(self):
        r = load().home_channels()
        self.assertFalse(r["ok"])
        self.assertNotIn("chat_id", str(r))

    def test_registers_rpc(self):
        got = {}

        class Ctx:
            def register_rpc(self, name, fn):
                got[name] = fn

        load().register(Ctx())
        self.assertEqual(set(got), {"set_main_model", "telegram_status", "telegram_save", "account_usage", "home_channels"})

    def test_telegram_save_checks_input_before_touching_hermes(self):
        m = load()
        self.assertFalse(m.telegram_save({"token": "nope"})["ok"])
        self.assertFalse(m.telegram_save({"allowed_users": "abc"})["ok"])
        self.assertFalse(m.telegram_save({})["ok"])

    def test_telegram_status_without_hermes_reports_and_never_returns_a_token(self):
        r = load().telegram_status()
        self.assertNotIn("token", r)


if __name__ == "__main__":
    unittest.main()
