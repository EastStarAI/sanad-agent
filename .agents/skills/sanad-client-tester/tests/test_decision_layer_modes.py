import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.candidates import RESERVED, extract  # noqa: E402
from decision_layer.guard import (  # noqa: E402
    DIALOG_BLOCKING,
    MODE_MISMATCH,
    UNKNOWN_MODE,
    evaluate_pre,
)
from decision_layer.layer import DecisionRequest  # noqa: E402
from decision_layer.modes import (  # noqa: E402
    ASK_USER_CARD,
    COMPOSER_POPUP,
    CONVERSATION_IDLE,
    CONVERSATION_RUNNING,
    CONVERSATION_SEARCH,
    KNOWN_MODES,
    MODEL_PICKER,
    PERMISSION_CARD,
    SETTINGS,
    UNKNOWN,
    classify,
)
from decision_layer.observation import Observation  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "snapshots"


def _elements(*keys: str) -> tuple:
    """Build a minimal element list from widget keys."""
    return tuple(
        {
            "type": "TextField" if key.endswith("_input") or key.endswith("_field") else "InkWell",
            "key": key,
            "text": None,
            "enabled": True,
        }
        for key in keys
    )


class ModeClassificationTest(unittest.TestCase):
    def test_every_fixture_matches_its_recorded_mode(self):
        labels = json.loads(
            (FIXTURES.parent / "labels.json").read_text(encoding="utf-8")
        )["decisions"]
        for label in labels:
            payload = json.loads(
                (FIXTURES / label["snapshot"]).read_text(encoding="utf-8")
            )
            evidence = classify(Observation.from_snapshot(payload).elements)
            self.assertEqual(evidence.mode, label["mode"], label["snapshot"])
            self.assertEqual(
                evidence.detail, label["mode_detail"], label["snapshot"]
            )
            self.assertTrue(evidence.matched, label["snapshot"])

    def test_fixtures_cover_at_least_six_known_modes(self):
        labels = json.loads(
            (FIXTURES.parent / "labels.json").read_text(encoding="utf-8")
        )["decisions"]
        covered = {label["mode"] for label in labels}
        self.assertGreaterEqual(len(covered), 6)
        self.assertLessEqual(covered, set(KNOWN_MODES))
        for mode in (
            CONVERSATION_IDLE,
            CONVERSATION_RUNNING,
            PERMISSION_CARD,
            ASK_USER_CARD,
            MODEL_PICKER,
            SETTINGS,
        ):
            self.assertIn(mode, covered)

    def test_unknown_is_returned_instead_of_a_guess(self):
        self.assertEqual(classify(()).mode, UNKNOWN)
        self.assertEqual(classify(_elements("mystery_widget")).mode, UNKNOWN)
        table = extract(_elements("mystery_widget"), UNKNOWN)
        self.assertEqual(table.rows, ())
        self.assertEqual(list(table.candidates), list(RESERVED))

    def test_overlays_win_over_the_base_screen(self):
        base = ("chat_input", "send_message_btn")
        self.assertEqual(
            classify(_elements(*base, "model_picker_close_btn")).mode, MODEL_PICKER
        )
        self.assertEqual(
            classify(_elements(*base, "permission_option_once")).mode, PERMISSION_CARD
        )
        self.assertEqual(
            classify(_elements(*base, "predefined_option_1")).mode, ASK_USER_CARD
        )
        self.assertEqual(
            classify(_elements(*base, "thinking_mode_option_low")).mode,
            COMPOSER_POPUP,
        )
        self.assertEqual(
            classify(_elements(*base, "conversation_search_field")).mode,
            CONVERSATION_SEARCH,
        )
        self.assertEqual(
            classify(_elements(*base, "settings_back_to_conversations_btn")).mode,
            SETTINGS,
        )

    def test_running_conversation_is_distinguished_by_the_stop_control(self):
        self.assertEqual(
            classify(_elements("chat_input", "stop_message_btn")).mode,
            CONVERSATION_RUNNING,
        )
        self.assertEqual(
            classify(_elements("chat_input", "send_message_btn")).mode,
            CONVERSATION_IDLE,
        )

    def test_detail_is_derived_from_keys_not_from_text(self):
        self.assertEqual(
            classify(
                _elements("permission_option_once", "permission_deny_submit_button")
            ).detail,
            "deny_comment",
        )
        self.assertEqual(
            classify(_elements("permission_option_once")).detail, "options"
        )
        self.assertEqual(classify(_elements("predefined_option_1")).detail, "options")
        self.assertEqual(
            classify(_elements("back_to_options_btn")).detail, "custom_input"
        )

    def test_blockers_record_the_overlay_underneath(self):
        evidence = classify(_elements("thinking_mode_option_low", "permission_option_deny"))
        self.assertEqual(evidence.mode, PERMISSION_CARD)
        self.assertIn(COMPOSER_POPUP, evidence.blockers)


class PreCheckTest(unittest.TestCase):
    def _pre(self, mode_evidence, request, table=None):
        observation = Observation(elements=_elements("chat_input"))
        return evaluate_pre(
            observation, request, mode_evidence, table or extract((), mode_evidence.mode)
        )

    def test_unknown_mode_escalates_before_any_model_call(self):
        observation = Observation(elements=())
        evidence = classify(())
        request = DecisionRequest(goal="g", phase="p")
        refusal = evaluate_pre(observation, request, evidence, extract((), UNKNOWN))
        self.assertIsNotNone(refusal)
        self.assertEqual(refusal.code, UNKNOWN_MODE)

    def test_mode_mismatch_is_reported(self):
        observation = Observation(elements=_elements("chat_input"))
        evidence = classify(observation.elements)
        table = extract(observation.elements, evidence.mode)
        request = DecisionRequest(goal="g", phase="p", expected_mode=SETTINGS)
        refusal = evaluate_pre(observation, request, evidence, table)
        self.assertEqual(refusal.code, MODE_MISMATCH)

    def test_overlay_under_a_base_phase_is_a_blocker(self):
        observation = Observation(elements=_elements("chat_input", "permission_option_once"))
        evidence = classify(observation.elements)
        table = extract(observation.elements, evidence.mode)
        request = DecisionRequest(goal="g", phase="p", expected_mode=CONVERSATION_IDLE)
        refusal = evaluate_pre(observation, request, evidence, table)
        self.assertEqual(refusal.code, DIALOG_BLOCKING)

    def test_unsettled_and_unhealthy_snapshots_are_refused(self):
        evidence = classify(_elements("chat_input"))
        table = extract(_elements("chat_input"), evidence.mode)
        request = DecisionRequest(goal="g", phase="p")
        for observation, code in (
            (
                Observation(elements=_elements("chat_input"), settled=False),
                "not_settled",
            ),
            (Observation(elements=_elements("chat_input"), status="stale"), "observation_not_ok"),
        ):
            refusal = evaluate_pre(observation, request, evidence, table)
            self.assertEqual(refusal.code, code)


if __name__ == "__main__":
    unittest.main()
