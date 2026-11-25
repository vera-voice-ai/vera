"""Offline: actions are checked, Vera's binary is called the right way, failures come back as sentences."""
import importlib.util
import os
import pathlib
import stat
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("vera_browser", ROOT / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BrowserTest(unittest.TestCase):
    def setUp(self):
        self.mod = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.bin = pathlib.Path(self.tmp.name) / "Vera"
        # A stand-in for Vera: prints its arguments and the data root it was given.
        self.bin.write_text('#!/bin/sh\necho "$1 $2 $VERA_DATA_ROOT"\n')
        self.bin.chmod(self.bin.stat().st_mode | stat.S_IEXEC)

    def tearDown(self):
        self.tmp.cleanup()

    def test_calls_vera_with_the_action_and_data(self):
        r = self.mod.run("hide", binary=str(self.bin), data="/D/Vera03")
        self.assertEqual(r, {"ok": True, "text": "--browser hide /D/Vera03"})

    def test_unknown_action(self):
        self.assertFalse(self.mod.run("explode", binary=str(self.bin))["ok"])

    def test_without_vera(self):
        os.environ.pop("VERA_EARS_BIN", None)
        self.assertFalse(self.mod.run("open")["ok"])

    def _hook(self, tool, port_open):
        calls = []
        self.mod.port_open = lambda *a, **k: port_open
        self.mod.run = lambda action, **k: calls.append(action) or {"ok": True, "text": ""}
        os.environ["VERA_EARS_BIN"] = str(self.bin)
        try:
            self.assertIsNone(self.mod.pre_tool_call(tool_name=tool, args={"code": "x"}))
        finally:
            os.environ.pop("VERA_EARS_BIN", None)
        return calls

    def test_page_tool_opens_the_closed_browser(self):
        self.assertEqual(self._hook("browser_exec", port_open=False), ["open"])

    def test_open_browser_is_left_alone(self):
        self.assertEqual(self._hook("browser_exec", port_open=True), [])

    def test_other_tools_do_not_open_it(self):
        self.assertEqual(self._hook("terminal", port_open=False), [])
        self.assertEqual(self._hook("browser_vault", port_open=False), [])


if __name__ == "__main__":
    unittest.main()
