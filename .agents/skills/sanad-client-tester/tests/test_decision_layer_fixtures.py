import json
import re
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.candidates import extract  # noqa: E402
from decision_layer.modes import classify  # noqa: E402
from decision_layer.observation import Observation  # noqa: E402

FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures"
SNAPSHOTS = FIXTURE_ROOT / "snapshots"
LABELS = FIXTURE_ROOT / "labels.json"

# Token-shaped patterns only, so ordinary labels such as "ask-user-card" are not
# mistaken for secrets.
SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(r"AIza[0-9A-Za-z_\-]{20,}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"Bearer\s+[A-Za-z0-9_\-\.]{20,}"),
    re.compile(r"TYPESAFE_API_KEY\s*="),
)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ABSOLUTE_PATH = re.compile(r"/(?:Users|Volumes|home|private|opt|srv|mnt)/")
ENTERED_VALUES = ("probe",)


def _labels():
    return json.loads(LABELS.read_text(encoding="utf-8"))["decisions"]


class FixtureHygieneTest(unittest.TestCase):
    def test_fixture_and_label_sets_match_one_to_one(self):
        names = {path.name for path in SNAPSHOTS.glob("*.json")}
        labelled = {label["snapshot"] for label in _labels()}
        self.assertEqual(len(names), 24)
        self.assertEqual(names, labelled)

    def test_no_secret_personal_data_or_machine_path_reaches_a_fixture(self):
        for path in sorted(SNAPSHOTS.glob("*.json")):
            text = path.read_text(encoding="utf-8")
            for pattern in SECRET_PATTERNS:
                self.assertIsNone(pattern.search(text), path.name)
            self.assertIsNone(EMAIL.search(text), path.name)
            self.assertIsNone(ABSOLUTE_PATH.search(text), path.name)

    def test_no_secret_reaches_the_label_file(self):
        text = LABELS.read_text(encoding="utf-8")
        for pattern in SECRET_PATTERNS:
            self.assertIsNone(pattern.search(text))
        self.assertIsNone(EMAIL.search(text))
        self.assertIsNone(ABSOLUTE_PATH.search(text))

    def test_snapshots_still_look_like_driver_snapshots(self):
        for path in sorted(SNAPSHOTS.glob("*.json")):
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload["status"], "ok", path.name)
            self.assertIsInstance(payload["elements"], list, path.name)
            self.assertGreaterEqual(len(payload["elements"]), 90, path.name)
            self.assertEqual(payload["count"], len(payload["elements"]), path.name)

    def test_no_entered_value_is_stored_as_a_decision_label(self):
        labels = LABELS.read_text(encoding="utf-8")
        for value in ENTERED_VALUES:
            self.assertNotIn(f'"{value}"', labels)


class LabelReachabilityTest(unittest.TestCase):
    def test_every_accepted_id_exists_in_the_mode_scoped_table(self):
        for label in _labels():
            payload = json.loads(
                (SNAPSHOTS / label["snapshot"]).read_text(encoding="utf-8")
            )
            observation = Observation.from_snapshot(payload)
            evidence = classify(observation.elements)
            self.assertEqual(evidence.mode, label["mode"], label["snapshot"])
            self.assertEqual(evidence.detail, label["mode_detail"], label["snapshot"])
            table = extract(observation.elements, evidence.mode, evidence.detail)
            for candidate_id in label["correct"]:
                if candidate_id == "abstain":
                    continue
                self.assertIn(
                    candidate_id,
                    table.candidates,
                    f"{label['snapshot']}: {candidate_id} is not offered by the table",
                )

    def test_trap_labels_explain_themselves(self):
        for label in _labels():
            if label["trap"]:
                self.assertTrue(
                    label.get("rationale"), f"{label['snapshot']} needs a rationale"
                )

    def test_guard_enforced_labels_accept_no_action(self):
        for label in _labels():
            if not label["guard_enforced"]:
                continue
            self.assertEqual(label["correct"], ["abstain"], label["snapshot"])

    def test_recorded_action_irreversibility_matches_the_action_table(self):
        for label in _labels():
            payload = json.loads(
                (SNAPSHOTS / label["snapshot"]).read_text(encoding="utf-8")
            )
            observation = Observation.from_snapshot(payload)
            evidence = classify(observation.elements)
            table = extract(observation.elements, evidence.mode, evidence.detail)
            flags = [
                table.row(candidate_id).irreversible
                for candidate_id in label["correct"]
                if candidate_id != "abstain" and table.row(candidate_id) is not None
            ]
            self.assertEqual(
                label["action_irreversible"],
                any(flags),
                label["snapshot"],
            )

    def test_traps_and_answerable_cases_are_both_present(self):
        labels = _labels()
        self.assertGreaterEqual(sum(1 for label in labels if label["trap"]), 5)
        self.assertGreaterEqual(
            sum(1 for label in labels if label["correct"] != ["abstain"]), 15
        )
        self.assertGreaterEqual(sum(1 for label in labels if label["irreversible"]), 6)


if __name__ == "__main__":
    unittest.main()
