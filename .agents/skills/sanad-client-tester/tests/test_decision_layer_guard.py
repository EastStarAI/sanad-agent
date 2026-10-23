import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.actions import ACTION_RULES  # noqa: E402
from decision_layer.candidates import Candidate, CandidateTable, extract  # noqa: E402
from decision_layer.guard import (  # noqa: E402
    DISABLED_TARGET,
    INVALID_TARGET,
    IRREVERSIBLE_NOT_AUTHORIZED,
    MODEL_ABSTAINED,
    MODEL_REOBSERVE,
    PHASE_REENTRY,
    PRECONDITION_FAILED,
    REPEATED_TARGET,
    TARGET_ABSENT,
    UNCLASSIFIED_TARGET,
    evaluate_post,
)
from decision_layer.layer import DecisionLayer, DecisionRequest  # noqa: E402
from decision_layer.model import (  # noqa: E402
    DecisionModel,
    FakeDecisionModel,
    ModelChoice,
)
from decision_layer.modes import classify  # noqa: E402
from decision_layer.observation import Observation  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "snapshots"


def _observation(name: str, *, drop=(), disable=(), ref=None) -> Observation:
    payload = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    elements = [
        dict(element)
        for element in payload["elements"]
        if element.get("key") not in drop
    ]
    for element in elements:
        if element.get("key") in disable:
            element["enabled"] = False
    return Observation.from_snapshot({"elements": elements}, ref=ref or name)


def _decide(name: str, phase: str, choice: str, *, confidence=0.99, authorize=(), observation=None):
    layer = DecisionLayer(FakeDecisionModel(choice, confidence))
    request = DecisionRequest(
        goal="a test goal", phase=phase, authorizations=frozenset(authorize)
    )
    outcome = layer.decide(observation or _observation(name), request)
    return layer, outcome


def _filled_trap_observation() -> Observation:
    """Fixture 17 with the answer field filled, so the submit is admissible."""
    payload = json.loads(
        (FIXTURES / "17-ask-user-custom-input.json").read_text(encoding="utf-8")
    )
    elements = [
        dict(element, text="app/")
        if element.get("key") == "clarifying_question_input"
        else element
        for element in payload["elements"]
    ]
    return Observation.from_snapshot({"elements": elements})


class P0TrapTest(unittest.TestCase):
    """The measured P0 failure: submit selected at 0.98 with an empty field.

    Two independent refusals now cover it. The extractor never offers an
    un-fillable submit, so the model cannot choose it at all; and the post-model
    guard still refuses it whenever a stale table does contain it.
    """

    def test_the_trap_candidate_is_never_sent_to_the_model(self):
        observation = _observation("17-ask-user-custom-input.json")
        evidence = classify(observation.elements)
        table = extract(observation.elements, evidence.mode, evidence.detail)
        self.assertNotIn("submit_question_answer_btn", table.candidates)
        self.assertIn("submit_question_answer_btn", table.pruned)
        self.assertEqual(table.dropped["precondition-failed"], 1)
        # The field itself stays available, so "type first" is still answerable.
        self.assertIn("clarifying_question_input", table.candidates)

    def test_the_model_receives_the_filtered_table_only(self):
        seen = {}

        class _CapturingModel(FakeDecisionModel):
            def choose(self, context):
                seen.update(context.candidates)
                return super().choose(context)

        layer = DecisionLayer(_CapturingModel("abstain", 0.99))
        outcome = layer.decide(
            _observation("17-ask-user-custom-input.json"),
            DecisionRequest(goal="submit the typed answer", phase="submit_custom_answer"),
        )
        self.assertNotIn("submit_question_answer_btn", seen)
        self.assertEqual(outcome.escalation.reason_code, MODEL_ABSTAINED)

    def test_the_trap_id_is_still_refused_even_at_099(self):
        layer, outcome = _decide(
            "17-ask-user-custom-input.json",
            "submit_custom_answer",
            "submit_question_answer_btn",
            confidence=0.99,
        )
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, INVALID_TARGET)
        self.assertEqual(outcome.escalation.selected, "submit_question_answer_btn")
        # The model was consulted, and its high confidence bought nothing.
        self.assertEqual(layer.model.calls, ["submit_custom_answer"])

    def test_the_post_model_guard_still_refuses_a_stale_table(self):
        """The guard keeps its own check; the pre-filter is not a replacement."""
        filled = _filled_trap_observation()
        evidence = classify(filled.elements)
        table = extract(filled.elements, evidence.mode, evidence.detail)
        self.assertIn("submit_question_answer_btn", table.candidates)
        # The screen then goes empty: exactly what a stale admission looks like.
        refusal = evaluate_post(
            _observation("17-ask-user-custom-input.json"),
            DecisionRequest(goal="g", phase="submit_custom_answer"),
            evidence,
            table,
            "submit_question_answer_btn",
        )
        self.assertEqual(refusal.code, PRECONDITION_FAILED)
        self.assertIn("clarifying_question_input", refusal.detail)

    def test_structural_refusal_is_reported_before_low_confidence(self):
        filled = _filled_trap_observation()
        evidence = classify(filled.elements)
        table = extract(filled.elements, evidence.mode, evidence.detail)
        for confidence in (0.10, 0.99):
            refusal = evaluate_post(
                _observation("17-ask-user-custom-input.json"),
                DecisionRequest(goal="g", phase="submit_custom_answer"),
                evidence,
                table,
                "submit_question_answer_btn",
            )
            self.assertEqual(refusal.code, PRECONDITION_FAILED, confidence)

    def test_a_filled_field_is_admitted(self):
        _layer, outcome = _decide(
            "17-ask-user-custom-input.json",
            "submit_custom_answer",
            "submit_question_answer_btn",
            observation=_filled_trap_observation(),
        )
        self.assertTrue(outcome.ok, outcome.escalation and outcome.escalation.to_dict())
        self.assertEqual(outcome.admitted.candidate_id, "submit_question_answer_btn")
        # The entered value is never part of the admitted record.
        self.assertNotIn("app/", json.dumps(outcome.admitted.to_dict()))


class IrreversibleBoundaryTest(unittest.TestCase):
    def test_required_irreversible_classes_are_declared(self):
        names = {rule.name for rule in ACTION_RULES if rule.irreversible}
        for required in (
            "send_message",
            "delete_account",
            "sign_out",
            "approve_once",
            "approve_session",
            "approve_workspace",
            "permission_mode_grant",
            "restart_agent",
            "apply_update",
            "remove_workspace",
            "provider_delete",
        ):
            self.assertIn(required, names)

    def test_no_irreversible_action_is_ever_admitted_on_the_model_alone(self):
        exercised = 0
        for path in sorted(FIXTURES.glob("*.json")):
            payload = json.loads(path.read_text(encoding="utf-8"))
            observation = Observation.from_snapshot(payload)
            evidence = classify(observation.elements)
            table = extract(observation.elements, evidence.mode, evidence.detail)
            for row in table.rows:
                if not row.irreversible:
                    continue
                exercised += 1
                _layer, denied = _decide(
                    path.name, "phase", row.id, observation=observation
                )
                self.assertFalse(denied.ok, f"{path.name}:{row.id} was admitted")
                self.assertIn(
                    denied.escalation.reason_code,
                    {IRREVERSIBLE_NOT_AUTHORIZED, PRECONDITION_FAILED},
                    f"{path.name}:{row.id}",
                )
                if denied.escalation.reason_code == IRREVERSIBLE_NOT_AUTHORIZED:
                    self.assertTrue(denied.escalation.irreversible)
                _layer, allowed = _decide(
                    path.name, "phase", row.id, authorize=(row.id,), observation=observation
                )
                self.assertNotEqual(
                    allowed.escalation and allowed.escalation.reason_code,
                    IRREVERSIBLE_NOT_AUTHORIZED,
                    f"{path.name}:{row.id} must be admissible once authorized",
                )
        self.assertGreaterEqual(exercised, 8)

    def test_delete_and_sign_out_are_refused_and_explained(self):
        for candidate_id, rule_name in (
            ("delete_account_btn", "delete_account"),
            ("sign_out_btn", "sign_out"),
        ):
            _layer, outcome = _decide(
                "24-settings-profile.json", "profile_action", candidate_id
            )
            self.assertEqual(outcome.escalation.reason_code, IRREVERSIBLE_NOT_AUTHORIZED)
            self.assertIn(rule_name, outcome.escalation.detail)


class StructuralGuardTest(unittest.TestCase):
    def _table_and_post(self, name, choice, *, drop=(), disable=()):
        base = _observation(name)
        evidence = classify(base.elements)
        table = extract(base.elements, evidence.mode, evidence.detail)
        observation = _observation(name, drop=drop, disable=disable)
        request = DecisionRequest(goal="g", phase="p")
        return evaluate_post(observation, request, evidence, table, choice)

    def test_target_absent_after_the_screen_changed(self):
        refusal = self._table_and_post(
            "16-ask-user-card.json",
            "predefined_option_2",
            drop=("predefined_option_2",),
        )
        self.assertEqual(refusal.code, TARGET_ABSENT)

    def test_disabled_target(self):
        refusal = self._table_and_post(
            "16-ask-user-card.json",
            "predefined_option_2",
            disable=("predefined_option_2",),
        )
        self.assertEqual(refusal.code, DISABLED_TARGET)

    def test_invalid_target(self):
        refusal = self._table_and_post("16-ask-user-card.json", "invented_btn")
        self.assertEqual(refusal.code, INVALID_TARGET)

    def test_declines_are_escalations_not_actions(self):
        self.assertEqual(
            self._table_and_post("16-ask-user-card.json", "abstain").code,
            MODEL_ABSTAINED,
        )
        self.assertEqual(
            self._table_and_post("16-ask-user-card.json", "reobserve").code,
            MODEL_REOBSERVE,
        )

    def test_undeclared_control_fails_closed(self):
        observation = _observation("16-ask-user-card.json")
        evidence = classify(observation.elements)
        table = CandidateTable(
            mode=evidence.mode,
            mode_detail=evidence.detail,
            rows=(
                Candidate(
                    id="mystery_btn",
                    key="mystery_btn",
                    description="tap: mystery",
                    action="tap",
                    rule="undeclared",
                    family="mystery",
                    tier="decision",
                    irreversible=False,
                    filled=None,
                    selected=False,
                    order=0,
                ),
            ),
            candidates={"mystery_btn": "tap: mystery"},
            truncated=(),
            dropped={},
            element_count=1,
        )
        appended = Observation.from_snapshot(
            {"elements": list(observation.elements) + [{"type": "InkWell", "key": "mystery_btn", "enabled": True}]}
        )
        refusal = evaluate_post(
            appended,
            DecisionRequest(goal="g", phase="p"),
            evidence,
            table,
            "mystery_btn",
        )
        self.assertEqual(refusal.code, UNCLASSIFIED_TARGET)

    def test_denial_submit_requires_the_deny_form(self):
        """The extractor prunes this form; the guard still reports the reason.

        The table is built from the complete screen and checked against the screen
        that lost its deny-comment field: a stale table, which is the only way this
        candidate can reach the guard any more.
        """
        complete = _observation("21-permission-deny-comment.json")
        evidence = classify(complete.elements)
        table = extract(complete.elements, evidence.mode, evidence.detail)
        payload = json.loads(
            (FIXTURES / "21-permission-deny-comment.json").read_text(encoding="utf-8")
        )
        observation = Observation.from_snapshot(
            {
                "elements": [
                    element
                    for element in payload["elements"]
                    if element.get("key") != "permission_deny_comment_input"
                ]
            }
        )
        refusal = evaluate_post(
            observation,
            DecisionRequest(goal="g", phase="p"),
            evidence,
            table,
            "permission_deny_submit_button",
        )
        self.assertEqual(refusal.code, PRECONDITION_FAILED)
        self.assertIn("permission_deny_comment_input", refusal.detail)
        # And on the complete screen the extractor keeps it, since the form exists.
        stripped = extract(observation.elements, evidence.mode, evidence.detail)
        self.assertIn("permission_deny_submit_button", stripped.pruned)


class _RotatingModel(DecisionModel):
    """One target per call, in order, so a phase can legitimately repeat."""

    name = "rotating"

    def __init__(self, choices) -> None:
        self._choices = tuple(choices)
        self.calls = []

    def choose(self, context) -> ModelChoice:
        self.calls.append(context.phase)
        target = self._choices[(len(self.calls) - 1) % len(self._choices)]
        return ModelChoice(
            choice=target,
            confidence=0.99,
            probabilities={target: 0.99, "abstain": 0.01},
            latency_ms=1,
            model="rotating-1",
        )


class PhaseReentryTest(unittest.TestCase):
    """F-03: a completed irreversible phase can never be decided again."""

    def test_a_completed_irreversible_phase_is_refused_before_the_model(self):
        layer = DecisionLayer(FakeDecisionModel("permission_option_once", 0.99))
        request = DecisionRequest(
            goal="allow this read once",
            phase="approve_once",
            authorizations=frozenset({"permission_option_once"}),
        )
        first = layer.decide(_observation("20-permission-card.json"), request)
        self.assertTrue(first.ok)
        self.assertIsNone(
            layer.record_action("approve_once", first.admitted.candidate_id, "before", "after")
        )
        self.assertEqual(layer.irreversible_phases, {"approve_once"})
        calls = list(layer.model.calls)

        again = layer.decide(_observation("20-permission-card.json"), request)
        self.assertFalse(again.ok)
        self.assertEqual(again.escalation.reason_code, PHASE_REENTRY)
        self.assertEqual(again.escalation.guard["phase"], "approve_once")
        # The provider was never asked to re-authorize what already happened.
        self.assertEqual(layer.model.calls, calls)

    def test_an_unrecorded_irreversible_step_does_not_burn_the_phase(self):
        layer = DecisionLayer(FakeDecisionModel("permission_option_once", 0.99))
        request = DecisionRequest(
            goal="allow this read once",
            phase="approve_once",
            authorizations=frozenset({"permission_option_once"}),
        )
        self.assertTrue(layer.decide(_observation("20-permission-card.json"), request).ok)
        # The dispatch never happened, so the phase is still decidable.
        self.assertEqual(layer.irreversible_phases, set())
        self.assertTrue(layer.decide(_observation("20-permission-card.json"), request).ok)

    def test_a_completed_reversible_phase_may_repeat(self):
        layer = DecisionLayer(
            _RotatingModel(("nav_tile_profile", "nav_tile_general", "nav_tile_overview"))
        )
        observation = _observation("08-settings-root.json")
        for index in range(3):
            outcome = layer.decide(
                observation, DecisionRequest(goal="open a settings page", phase="navigate")
            )
            self.assertTrue(outcome.ok, index)
            self.assertIsNone(
                layer.record_action(
                    "navigate",
                    outcome.admitted.candidate_id,
                    f"before{index}",
                    f"after{index}",
                )
            )
        self.assertEqual(layer.model.calls, ["navigate"] * 3)
        self.assertEqual(layer.irreversible_phases, set())
        self.assertEqual(layer.completed_phases, ("navigate",))


class DispatchTimeRevalidationTest(unittest.TestCase):
    def test_a_stale_admission_is_refused_at_dispatch_time(self):
        layer, outcome = _decide(
            "01-conversation-idle.json",
            "send_message",
            "send_message_btn",
            authorize=("send_message_btn",),
        )
        self.assertTrue(outcome.ok)
        emptied = json.loads(
            (FIXTURES / "01-conversation-idle.json").read_text(encoding="utf-8")
        )
        for element in emptied["elements"]:
            if element.get("key") == "chat_input":
                element["text"] = ""
        revalidated = layer.revalidate(
            outcome.admitted,
            Observation.from_snapshot(emptied),
            DecisionRequest(goal="g", phase="send_message", authorizations=frozenset({"send_message_btn"})),
        )
        self.assertFalse(revalidated.ok)
        self.assertEqual(revalidated.escalation.reason_code, PRECONDITION_FAILED)

    def test_revalidation_passes_on_an_unchanged_screen(self):
        layer, outcome = _decide(
            "20-permission-card.json",
            "approve_once",
            "permission_option_once",
            authorize=("permission_option_once",),
        )
        self.assertTrue(outcome.ok)
        revalidated = layer.revalidate(
            outcome.admitted,
            _observation("20-permission-card.json"),
            DecisionRequest(
                goal="g",
                phase="approve_once",
                authorizations=frozenset({"permission_option_once"}),
            ),
        )
        self.assertTrue(revalidated.ok)


class CircuitBreakerIntegrationTest(unittest.TestCase):
    def test_the_same_target_three_times_trips_before_dispatch(self):
        layer = DecisionLayer(FakeDecisionModel("nav_tile_profile", 0.99))
        request = DecisionRequest(goal="open profile", phase="navigate")
        observation = _observation("08-settings-root.json")
        for index in range(2):
            outcome = layer.decide(observation, request)
            self.assertTrue(outcome.ok, index)
            self.assertIsNone(
                layer.record_action(request.phase, "nav_tile_profile", "a", f"b{index}")
            )
        third = layer.decide(observation, request)
        self.assertFalse(third.ok)
        self.assertEqual(third.escalation.reason_code, REPEATED_TARGET)


if __name__ == "__main__":
    unittest.main()
