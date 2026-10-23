import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.candidates import MAX_CANDIDATES, RESERVED, extract  # noqa: E402
from decision_layer.modes import (  # noqa: E402
    ASK_USER_CARD,
    CONVERSATION_IDLE,
    MODEL_PICKER,
    PERMISSION_CARD,
    SETTINGS,
    classify,
)
from decision_layer.observation import Observation  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "snapshots"


def _load(name: str) -> Observation:
    payload = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    return Observation.from_snapshot(payload, ref=name)


def _table(name: str):
    observation = _load(name)
    evidence = classify(observation.elements)
    return extract(observation.elements, evidence.mode, evidence.detail)


class ExtractorDeterminismTest(unittest.TestCase):
    def test_identical_output_on_repeat_runs(self):
        for path in sorted(FIXTURES.glob("*.json")):
            first = _table(path.name)
            second = _table(path.name)
            self.assertEqual(
                json.dumps(first.descriptions(), sort_keys=False),
                json.dumps(second.descriptions(), sort_keys=False),
                path.name,
            )
            self.assertEqual(
                [row.to_dict() for row in first.rows],
                [row.to_dict() for row in second.rows],
                path.name,
            )
            self.assertEqual(first.truncated, second.truncated, path.name)

    def test_rerun_from_disk_matches_in_memory_table(self):
        for path in sorted(FIXTURES.glob("*.json")):
            payload = json.loads(path.read_text(encoding="utf-8"))
            observation = Observation.from_snapshot(payload, ref=path.name)
            evidence = classify(observation.elements)
            table = extract(observation.elements, evidence.mode, evidence.detail)
            again = extract(
                Observation.from_snapshot(payload).elements, evidence.mode, evidence.detail
            )
            self.assertEqual(table.descriptions(), again.descriptions(), path.name)


class ExtractorContractTest(unittest.TestCase):
    def test_reserved_declines_are_always_present(self):
        for path in sorted(FIXTURES.glob("*.json")):
            table = _table(path.name)
            for reserved in RESERVED:
                self.assertIn(reserved, table.candidates)

    def test_candidate_count_never_exceeds_the_cap(self):
        for path in sorted(FIXTURES.glob("*.json")):
            table = _table(path.name)
            self.assertLessEqual(len(table.candidates), MAX_CANDIDATES, path.name)
            self.assertEqual(len(table.candidates), len(table.rows) + len(RESERVED))

    def test_ids_are_unique(self):
        for path in sorted(FIXTURES.glob("*.json")):
            table = _table(path.name)
            ids = [row.id for row in table.rows]
            self.assertEqual(len(ids), len(set(ids)), path.name)

    def test_disabled_controls_are_never_offered(self):
        for path in sorted(FIXTURES.glob("*.json")):
            observation = _load(path.name)
            table = _table(path.name)
            for row in table.rows:
                element = observation.keyed(row.key)
                self.assertIsNotNone(element, f"{path.name}:{row.id}")
                self.assertIsNot(element.get("enabled"), False, f"{path.name}:{row.id}")

    def test_text_field_contents_are_never_emitted(self):
        descriptions = " ".join(
            description
            for path in sorted(FIXTURES.glob("*.json"))
            for description in _table(path.name).descriptions().values()
        )
        for entered_value in ("probe", "Probe"):
            self.assertNotIn(entered_value, descriptions)
        self.assertIn("[filled]", descriptions)
        self.assertIn("[empty]", descriptions)

    def test_unclassified_and_layout_keys_are_dropped(self):
        observation = _load("01-conversation-idle.json")
        table = _table("01-conversation-idle.json")
        keys = {row.key for row in table.rows}
        self.assertNotIn("_ScaffoldSlot.body", keys)
        self.assertNotIn("chat_messages_list", keys)
        self.assertGreater(table.dropped["unclassified"], 0)
        self.assertGreaterEqual(len(observation.elements), 100)


class ExtractorModeScopeTest(unittest.TestCase):
    def test_conversation_mode_excludes_card_and_settings_controls(self):
        keys = {row.key for row in _table("01-conversation-idle.json").rows}
        self.assertIn("chat_input", keys)
        self.assertIn("send_message_btn", keys)
        for forbidden in (
            "permission_option_once",
            "delete_account_btn",
            "nav_tile_profile",
            "model_option_gpt-5.5",
        ):
            self.assertNotIn(forbidden, keys)

    def test_permission_card_scope_is_the_card(self):
        keys = {row.key for row in _table("20-permission-card.json").rows}
        self.assertEqual(
            keys,
            {
                "permission_option_once",
                "permission_option_session",
                "permission_option_workspace",
                "permission_option_deny",
            },
        )

    def test_ask_user_scope_is_the_card(self):
        table = _table("17-ask-user-custom-input.json")
        keys = {row.key for row in table.rows}
        self.assertIn("clarifying_question_input", keys)
        # The answer field is empty, so the submit cannot do anything useful and is
        # dropped before any model sees the table (F-04).
        self.assertNotIn("submit_question_answer_btn", keys)
        self.assertIn("submit_question_answer_btn", table.pruned)
        self.assertEqual(table.dropped["precondition-failed"], 1)
        self.assertNotIn("chat_input", keys)

    def test_model_picker_scope_is_the_picker(self):
        table = _table("03-model-picker.json")
        keys = {row.key for row in table.rows}
        self.assertIn("model_picker_search_input", keys)
        self.assertTrue(any(key.startswith("model_option_") for key in keys))
        self.assertNotIn("chat_input", keys)
        self.assertLess(len(table.rows), MAX_CANDIDATES - len(RESERVED))

    def test_settings_scope_excludes_composer_controls(self):
        keys = {row.key for row in _table("09-settings-mcp-servers.json").rows}
        self.assertIn("add-mcp-server", keys)
        self.assertIn("nav_tile_profile", keys)
        self.assertNotIn("send_message_btn", keys)
        self.assertNotIn("chat_input", keys)

    def test_device_page_keeps_the_restart_control_that_was_cut_before(self):
        keys = {row.key for row in _table("12-settings-device.json").rows}
        self.assertIn("device_restart_agent_button", keys)

    def test_every_mode_produces_a_bounded_table(self):
        modes = {}
        for path in sorted(FIXTURES.glob("*.json")):
            table = _table(path.name)
            modes[table.mode] = len(table.rows)
        self.assertGreaterEqual(len(modes), 6)
        for mode, count in modes.items():
            self.assertGreater(count, 0, mode)
            self.assertLessEqual(count + len(RESERVED), MAX_CANDIDATES, mode)

    def test_unknown_mode_offers_only_declines(self):
        table = extract((), "unknown")
        self.assertEqual(list(table.candidates), list(RESERVED))
        self.assertEqual(table.rows, ())

    def test_every_known_mode_declares_at_least_one_rule(self):
        from decision_layer.actions import rules_for_mode
        from decision_layer.modes import KNOWN_MODES

        for mode in KNOWN_MODES:
            self.assertTrue(rules_for_mode(mode), mode)


if __name__ == "__main__":
    unittest.main()
