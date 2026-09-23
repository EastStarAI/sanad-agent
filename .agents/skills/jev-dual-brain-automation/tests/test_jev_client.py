import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from jev_client import JevClient  # noqa: E402


class _Response:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


class JevClientTest(unittest.TestCase):
    def test_batch_preserves_complete_typed_answers(self):
        payload = {
            "answers": {
                "target": {
                    "choice": "send",
                    "probabilities": {"send": 0.93, "wait": 0.07},
                    "confidence": 0.88,
                },
                "severity": {
                    "score": 1.4,
                    "legend": ["low", "medium", "high"],
                    "probabilities": [0.1, 0.4, 0.5],
                    "confidence": 0.72,
                },
                "blocked": {"noul": 0.12},
            }
        }
        with patch("urllib.request.urlopen", return_value=_Response(payload)):
            response = JevClient(api_key="test-only").ask(
                {"screen": "conversation"},
                {
                    "target": {
                        "type": "choice",
                        "instructions": "Choose",
                        "criteria": {"send": "Send", "wait": "Wait"},
                    },
                    "severity": {
                        "type": "score",
                        "instructions": "Rate",
                        "criteria": ["low", "medium", "high"],
                    },
                    "blocked": {"type": "noul", "instructions": "Blocked?"},
                },
            )

        choice = response.answer("target", "choice")
        self.assertEqual(choice.choice, "send")
        self.assertEqual(choice.probability_for("send"), 0.93)
        self.assertEqual(choice.confidence, 0.88)
        self.assertEqual(response.answer("severity", "score").legend[2], "high")
        self.assertEqual(response.answer("blocked", "noul").noul, 0.12)

    def test_rejects_malformed_answer(self):
        with patch(
            "urllib.request.urlopen",
            return_value=_Response({"answers": {"bad": {"value": "unknown"}}}),
        ):
            with self.assertRaisesRegex(ValueError, "recognized typed value"):
                JevClient(api_key="test-only").ask(
                    "state", {"bad": {"type": "noul", "instructions": "?"}}
                )


if __name__ == "__main__":
    unittest.main()
