"""Offline: the provider reports failures as Hermes envelopes and never raises. Run: python3 -m unittest discover -s tests"""
import importlib.util
import os
import pathlib
import stat
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("vera_ears", ROOT / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def script(body: str) -> str:
    fd, path = tempfile.mkstemp(suffix=".sh")
    with os.fdopen(fd, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, stat.S_IRWXU)
    return path


class EarsTest(unittest.TestCase):
    def test_without_vera_binary_is_unavailable(self):
        mod = load()
        os.environ.pop("VERA_EARS_BIN", None)
        self.assertFalse(mod.GigaAMProvider().is_available())
        r = mod.transcribe_file("/nonexistent.ogg")
        self.assertFalse(r["success"])
        self.assertEqual(r["provider"], "gigaam")

    def test_transcript_from_stdout(self):
        r = load().transcribe_file("x.ogg", binary=script('[ "$1" = --transcribe ] && echo "  Привет, мир.  "'))
        self.assertEqual(r, {"success": True, "transcript": "Привет, мир.", "provider": "gigaam"})

    def test_failure_and_silence_are_errors(self):
        mod = load()
        self.assertIn("exited with 1", mod.transcribe_file("x", binary=script("echo bad >&2; exit 1"))["error"])
        self.assertIn("no speech", mod.transcribe_file("x", binary=script("echo"))["error"])

    def test_timeout_is_an_error(self):
        r = load().transcribe_file("x", binary=script("sleep 5"), timeout=0.3)
        self.assertFalse(r["success"])
        self.assertIn("did not finish", r["error"])

    def test_registers_the_provider(self):
        got = []
        class Ctx:
            def register_transcription_provider(self, p): got.append(p)
        load().register(Ctx())
        self.assertEqual(got[0].name, "gigaam")


if __name__ == "__main__":
    unittest.main()
