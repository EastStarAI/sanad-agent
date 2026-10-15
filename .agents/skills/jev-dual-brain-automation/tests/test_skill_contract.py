import json
import sys
import unittest
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL_ROOT / "scripts"


class SkillContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        cls.workflow = (SCRIPTS / "workflow_engine.py").read_text(encoding="utf-8")
        cls.browser = (SCRIPTS / "dual_brain_browser.py").read_text(encoding="utf-8")

    def test_skill_declares_software_owned_workflow(self):
        for phrase in (
            "Jev is not an agent",
            "structured state",
            "Questions in one request are independent",
            "classify hierarchically",
            "Reserve the phase",
            "Wait for events",
            "System 2",
        ):
            self.assertIn(phrase.lower(), self.skill.lower())

    def test_skill_routes_sanad_details_to_client_tester(self):
        self.assertIn("Sanad Client Tester", self.skill)
        self.assertIn("references/jev-conversation-automation.md", self.skill)
        self.assertFalse((SCRIPTS / "dual_brain_sanad_ui.py").exists())
        self.assertFalse((SCRIPTS / "sanad_conversation_workflow.py").exists())

    def test_browser_adapter_does_not_own_autonomous_goal_loops(self):
        self.assertNotIn("def execute_goal", self.browser)
        self.assertNotIn("JevClient", self.browser)
        self.assertNotIn("time.sleep", self.browser)

    def test_workflow_contains_required_fail_closed_controls(self):
        for symbol in (
            "DecisionPolicy",
            "PhaseLedger",
            "CircuitBreaker",
            "EventWaiter",
            "EscalationRequired",
            "irreversible_attempts",
            "NO_TRANSITION",
            "PHASE_REENTRY",
        ):
            self.assertIn(symbol, self.workflow)

    def test_evals_cover_browser_sanad_messages_confidence_and_blockers(self):
        payload = json.loads(
            (SKILL_ROOT / "evals" / "evals.json").read_text(encoding="utf-8")
        )
        self.assertEqual(payload["skill_name"], "jev-dual-brain-automation")
        self.assertEqual(len(payload["evals"]), 5)
        prompts = "\n".join(item["prompt"] for item in payload["evals"])
        for evidence in (
            "agent-browser",
            "Sanad Client",
            "send",
            "confidence 0.54",
            "fingerprint does not change",
        ):
            self.assertIn(evidence, prompts)
        self.assertTrue(all(item["expectations"] for item in payload["evals"]))

    def test_stale_unverified_performance_claims_are_removed(self):
        self.assertNotIn("$0.042", self.skill)
        self.assertNotIn("600ms", self.skill)
        self.assertNotIn("~700ms", self.skill)


if __name__ == "__main__":
    unittest.main()
