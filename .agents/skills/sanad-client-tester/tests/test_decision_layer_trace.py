import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.layer import DecisionLayer, DecisionRequest  # noqa: E402
from decision_layer.model import ScriptedDecisionModel  # noqa: E402
from decision_layer.observation import Observation  # noqa: E402
from decision_layer.trace import (  # noqa: E402
    TraceWriter,
    load_trace,
    replay,
    summarize,
)

# Token-shaped patterns only: "ask-user-card" is not a secret.
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
TOKEN = re.compile(
    r"(?:sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_\-]{20,}|ghp_[A-Za-z0-9]{20,})"
)

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "snapshots"


def _observation(name: str) -> Observation:
    payload = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    return Observation.from_snapshot(payload, ref=name)


class TraceRoundTripTest(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.path = Path(self._directory.name) / "trace.jsonl"

    def _run_two_steps(self) -> TraceWriter:
        writer = TraceWriter(self.path)
        layer = DecisionLayer(
            ScriptedDecisionModel(
                {
                    "answer": ("predefined_option_2", 0.93),
                    "submit_custom_answer": ("submit_question_answer_btn", 0.97),
                }
            ),
            trace=writer,
        )
        layer.decide(
            _observation("16-ask-user-card.json"),
            DecisionRequest(goal="Answer question 1", phase="answer"),
        )
        layer.decide(
            _observation("17-ask-user-custom-input.json"),
            DecisionRequest(goal="Submit the typed answer", phase="submit_custom_answer"),
        )
        return writer

    def test_every_step_is_replayable_from_the_jsonl_trace(self):
        self._run_two_steps()
        records = load_trace(self.path)
        self.assertEqual(len(records), 2)
        steps = replay(self.path)
        self.assertEqual([step["step"] for step in steps], [1, 2])
        self.assertEqual(steps[0]["verdict"], "admitted")
        self.assertEqual(steps[0]["action"]["id"], "predefined_option_2")
        self.assertEqual(steps[1]["verdict"], "escalated")
        self.assertEqual(steps[1]["reason_code"], "precondition_failed")
        for step in steps:
            self.assertTrue(step["mode"])
            self.assertTrue(step["candidate_ids"])
            self.assertIn("abstain", step["candidate_ids"])
            self.assertIn("reobserve", step["candidate_ids"])

    def test_trace_records_the_mode_evidence_and_the_cap(self):
        self._run_two_steps()
        records = load_trace(self.path)
        for record in records:
            self.assertTrue(record["mode_evidence"]["matched"])
            self.assertIn("generation", record["snapshot"])
            self.assertIn("fingerprint", record["snapshot"])
            self.assertIsInstance(record["truncated_ids"], list)
            self.assertIn("dropped", record)

    def test_trace_never_contains_entered_values_or_secrets(self):
        self._run_two_steps()
        text = self.path.read_text(encoding="utf-8")
        for forbidden in (
            "probe",
            "TYPESAFE_API_KEY",
            "Bearer ",
            "/Users/",
            "/Volumes/",
        ):
            self.assertNotIn(forbidden, text)
        self.assertIsNone(EMAIL.search(text))
        self.assertIsNone(TOKEN.search(text))

    def test_summary_counts_admissions_and_escalations(self):
        self._run_two_steps()
        summary = summarize(load_trace(self.path))
        self.assertEqual(summary["steps"], 2)
        self.assertEqual(summary["admitted"], 1)
        self.assertEqual(summary["escalated"], 1)
        self.assertAlmostEqual(summary["escalation_rate"], 0.5)
        self.assertEqual(summary["latency_ms"]["samples"], 2)

    def test_incomplete_records_are_rejected(self):
        writer = TraceWriter(self.path)
        with self.assertRaises(ValueError):
            writer.append({"step": 1, "verdict": "admitted"})
        with self.assertRaises(ValueError):
            writer.append(
                {
                    "step": 1,
                    "at": "now",
                    "phase": "p",
                    "goal": "g",
                    "mode": "settings",
                    "snapshot": {},
                    "candidate_ids": ["abstain"],
                    "model": "fake",
                    "verdict": "admitted",
                }
            )

    def test_non_contiguous_steps_are_rejected(self):
        writer = TraceWriter(self.path)
        writer.append(
            {
                "step": 1,
                "at": "now",
                "phase": "p",
                "goal": "g",
                "mode": "settings",
                "snapshot": {},
                "candidate_ids": ["abstain"],
                "model": "fake",
                "verdict": "escalated",
                "reason_code": "model_abstained",
            }
        )
        writer.append(
            {
                "step": 3,
                "at": "now",
                "phase": "p",
                "goal": "g",
                "mode": "settings",
                "snapshot": {},
                "candidate_ids": ["abstain"],
                "model": "fake",
                "verdict": "escalated",
                "reason_code": "model_abstained",
            }
        )
        with self.assertRaises(ValueError):
            replay(self.path)


if __name__ == "__main__":
    unittest.main()
