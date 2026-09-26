"""Tests for the translation sidecar protocol. Uses the echo engine, so no models or
third-party packages are needed:  python3 -m unittest discover -s python/tests
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PYTHON_DIR))

import translate_server  # noqa: E402
from translators import LANGS, Echo  # noqa: E402


class HandleTests(unittest.TestCase):
    def test_translates_supported_pair(self):
        reply = translate_server.handle(Echo(), {"id": 1, "text": "Hi", "source": "en", "target": "my"})
        self.assertEqual(reply, {"id": 1, "translation": "Hi"})

    def test_rejects_unknown_language(self):
        reply = translate_server.handle(Echo(), {"id": 2, "text": "Hi", "source": "xx", "target": "my"})
        self.assertEqual(reply["id"], 2)
        self.assertIn("unsupported", reply["error"])

    def test_same_language_and_blank_text_pass_through(self):
        self.assertEqual(translate_server.handle(Echo(), {"id": 3, "text": "  ", "source": "en", "target": "my"}),
                         {"id": 3, "translation": "  "})
        self.assertEqual(translate_server.handle(Echo(), {"id": 4, "text": "x", "source": "my", "target": "my"}),
                         {"id": 4, "translation": "x"})

    def test_language_table_matches_the_app(self):
        swift = (PYTHON_DIR.parent / "app/Sources/Subtitler/Translation/Languages.swift").read_text()
        for code in LANGS:
            self.assertIn(f'code: "{code}"', swift, f"{code} missing from Languages.swift")


class ProtocolTests(unittest.TestCase):
    def run_server(self, lines):
        result = subprocess.run(
            [sys.executable, str(PYTHON_DIR / "translate_server.py"), "--engine", "echo"],
            input="\n".join(lines) + "\n", capture_output=True, text=True, timeout=30, cwd=PYTHON_DIR)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_ready_then_one_reply_per_request(self):
        replies = self.run_server([
            json.dumps({"id": 1, "text": "Hello", "source": "en", "target": "my"}),
            json.dumps({"id": 2, "text": "မင်္ဂလာပါ", "source": "my", "target": "en"}, ensure_ascii=False),
        ])
        self.assertEqual(replies[0], {"ready": True, "engine": "echo"})
        self.assertEqual(replies[1:], [{"id": 1, "translation": "Hello"}, {"id": 2, "translation": "မင်္ဂလာပါ"}])

    def test_bad_json_is_reported_and_serving_continues(self):
        replies = self.run_server(["not json", json.dumps({"id": 5, "text": "ok", "source": "en", "target": "my"})])
        self.assertIn("bad json", replies[1]["error"])
        self.assertEqual(replies[2], {"id": 5, "translation": "ok"})


if __name__ == "__main__":
    unittest.main()
