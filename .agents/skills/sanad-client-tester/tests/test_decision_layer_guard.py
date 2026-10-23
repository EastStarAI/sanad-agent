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
    PRECONDITION_FAILED,
    REPEATED_TARGET,
    TARGET_ABSENT,
    UNCLASSIFIED_TARGET,
    evaluate_post,
)
from decision_layer.layer import DecisionLayer, DecisionRequest  # noqa: E402
from decision_layer.model import FakeDecisionModel  # noqa: E402
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


class P0TrapTest(unittest.TestCase):
    """The measured P0 failure: submit selected at 0.98 with an empty field."""

    def test_empty_field_submit_is_refused_even_at_099(self):
        layer, outcome = _decide(
            "17-ask-user-custom-input.json",
            "submit_custom_answer",
            "submit_question_answer_btn",
            confidence=0.99,
        )
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, PRECONDITION_FAILED)
        self.assertEqual(outcome.escalation.selected, "submit_question_answer_btn")
        self.assertIn("clarifying_question_input", outcome.escalation.detail)
        # The guard, not a pre-filter, did the work: the model was consulted.
        self.assertEqual(layer.model.calls, ["submit_custom_answer"])

    def test_structural_refusal_is_reported_before_low_confidence(self):
        _layer, outcome = _decide(
            "17-ask-user-custom-input.json",
            "submit_custom_answer",
            "submit_question_answer_btn",
            confidence=0.10,
        )
        self.assertEqual(outcome.escalation.reason_code, PRECONDITION_FAILED)

    def test_a_filled_field_is_admitted(self):
        payload = json.loads(
            (FIXTURES / "17-ask-user-custom-input.json").read_text(encoding="utf-8")
        )
        elements = [
            dict(element, text="app/") if element.get("key") == "clarifying_question_input" else element
            for element in payload["elements"]
        ]
        _layer, outcome = _decide(
            "17-ask-user-custom-input.json",
            "submit_custom_answer",
            "submit_question_answer_btn",
            observation=Observation.from_snapshot({"elements": elements}),
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
        evidence = classify(observation.elements)
        table = extract(observation.elements, evidence.mode, evidence.detail)
        refusal = evaluate_post(
            observation,
            DecisionRequest(goal="g", phase="p"),
            evidence,
            table,
            "permission_deny_submit_button",
        )
        self.assertEqual(refusal.code, PRECONDITION_FAILED)
        self.assertIn("permission_deny_comment_input", refusal.detail)


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
