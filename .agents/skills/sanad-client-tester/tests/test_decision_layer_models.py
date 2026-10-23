import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.bridge import (  # noqa: E402
    DecisionPolicy,
    JevAnswer,
    JevResponse,
    admit_choice,
)
from decision_layer.layer import DecisionLayer, DecisionRequest  # noqa: E402
from decision_layer.model import (  # noqa: E402
    DecisionContext,
    FakeDecisionModel,
    JevDecisionModel,
    ModelChoice,
    ScriptedDecisionModel,
    build_model,
)
from decision_layer.modes import classify  # noqa: E402
from decision_layer.observation import Observation  # noqa: E402
from decision_layer.candidates import extract  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "snapshots"


def _observation(name: str) -> Observation:
    payload = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    return Observation.from_snapshot(payload, ref=name)


class ModelChoiceContractTest(unittest.TestCase):
    def test_a_model_choice_satisfies_the_reusable_admission_gate(self):
        choice = ModelChoice(
            choice="send_message_btn",
            confidence=0.91,
            probabilities={"send_message_btn": 0.91, "abstain": 0.09},
        )
        admitted = admit_choice(
            choice,
            {"send_message_btn": "tap: send", "abstain": "decline"},
            DecisionPolicy(min_confidence=0.65),
        )
        self.assertEqual(admitted.target, "send_message_btn")
        self.assertAlmostEqual(admitted.probability, 0.91)

    def test_selected_probability_is_preserved(self):
        choice = ModelChoice(choice="a", confidence=0.8, probabilities={"a": 0.55, "b": 0.45})
        self.assertAlmostEqual(choice.probability_for("a"), 0.55)
        self.assertIsNone(choice.probability_for("missing"))


class ModelSwapTest(unittest.TestCase):
    """Swapping the model must not touch the extractor, the modes, or the guard."""

    def _run(self, model, fixture="16-ask-user-card.json", phase="answer"):
        observation = _observation(fixture)
        layer = DecisionLayer(model)
        return layer.decide(observation, DecisionRequest(goal="g", phase=phase))

    def test_two_models_see_the_same_screen_and_table(self):
        first = self._run(FakeDecisionModel("predefined_option_2", 0.95, name="alpha"))
        second = self._run(
            ScriptedDecisionModel({"answer": ("predefined_option_1", 0.9)}, name="beta")
        )
        self.assertEqual(first.mode_evidence, second.mode_evidence)
        self.assertEqual(first.candidate_count, second.candidate_count)
        self.assertEqual(first.admitted.candidate_id, "predefined_option_2")
        self.assertEqual(second.admitted.candidate_id, "predefined_option_1")
        self.assertEqual(first.admitted.mode, second.admitted.mode)

    def test_the_guard_binds_every_model_equally(self):
        trap = "17-ask-user-custom-input.json"
        for model in (
            FakeDecisionModel("submit_question_answer_btn", 0.99, name="alpha"),
            ScriptedDecisionModel(
                {"submit_custom_answer": ("submit_question_answer_btn", 0.98)},
                name="beta",
            ),
        ):
            # The layer only accepts one model per instance, so build it here.
            layer = DecisionLayer(model)
            outcome = layer.decide(
                _observation(trap),
                DecisionRequest(goal="g", phase="submit_custom_answer"),
            )
            self.assertFalse(outcome.ok, model.name)
            self.assertEqual(outcome.escalation.reason_code, "precondition_failed")


class JevAdapterTest(unittest.TestCase):
    class _StubClient:
        model = "jev-latest"

        def __init__(self, response):
            self._response = response
            self.calls = []

        def ask(self, state, questions, timeout=15):
            self.calls.append((state, questions, timeout))
            return self._response

    def _response(self, choice="nav_tile_profile", confidence=0.88, probability=0.88):
        return JevResponse(
            answers={
                "target": JevAnswer(
                    kind="choice",
                    choice=choice,
                    probabilities={choice: probability, "abstain": round(1 - probability, 4)},
                    confidence=confidence,
                    raw={},
                )
            },
            latency_ms=342,
            raw={
                "model": "jev-1.14.0",
                "usage": {"input_tokens": 1501, "output_tokens": 0},
            },
        )

    def _context(self) -> DecisionContext:
        observation = _observation("08-settings-root.json")
        evidence = classify(observation.elements)
        table = extract(observation.elements, evidence.mode, evidence.detail)
        return DecisionContext(
            goal="Open the Profile settings page",
            phase="navigate_settings",
            mode=evidence.mode,
            mode_detail=evidence.detail,
            candidates=table.descriptions(),
            completed_phases=("open_settings",),
            recent_actions=({"phase": "open_settings", "target": "sidebar_general_settings_destination"},),
        )

    def test_jev_answer_is_mapped_to_a_neutral_choice(self):
        client = self._StubClient(self._response())
        model = JevDecisionModel(client, timeout=3.0)
        choice = model.choose(self._context())
        self.assertEqual(choice.choice, "nav_tile_profile")
        self.assertAlmostEqual(choice.confidence, 0.88)
        self.assertEqual(choice.model, "jev-1.14.0")
        self.assertEqual(choice.latency_ms, 342)
        self.assertEqual(choice.metadata["input_tokens"], 1501)

    def test_request_is_structured_and_bounded(self):
        client = self._StubClient(self._response())
        model = JevDecisionModel(client)
        context = self._context()
        model.choose(context)
        state, questions, timeout = client.calls[0]
        self.assertEqual(timeout, 10.0)
        self.assertEqual(state["screen_mode"], "settings")
        self.assertEqual(state["screen_detail"], "general")
        self.assertEqual(state["completed_phases"], ["open_settings"])
        self.assertIn("nav_tile_profile", state["candidates"])
        self.assertEqual(questions["target"]["type"], "choice")
        self.assertEqual(set(questions["target"]["criteria"]), set(state["candidates"]))
        self.assertLessEqual(len(state["candidates"]), 32)


class BuildModelTest(unittest.TestCase):
    def test_fake_spec(self):
        model = build_model("fake:abstain:0.42")
        choice = model.choose(
            DecisionContext(goal="g", phase="p", mode="settings", mode_detail=None, candidates={"abstain": "x"})
        )
        self.assertEqual(choice.choice, "abstain")
        self.assertAlmostEqual(choice.confidence, 0.42)

    def test_scripted_spec(self):
        model = build_model("scripted:one=nav_tile_profile@0.9,two=abstain@0.3")
        self.assertIsInstance(model, ScriptedDecisionModel)
        choice = model.choose(
            DecisionContext(goal="g", phase="two", mode="settings", mode_detail=None, candidates={})
        )
        self.assertEqual(choice.choice, "abstain")

    def test_unknown_spec_fails_closed(self):
        with self.assertRaises(ValueError):
            build_model("gpt-5")


if __name__ == "__main__":
    unittest.main()
