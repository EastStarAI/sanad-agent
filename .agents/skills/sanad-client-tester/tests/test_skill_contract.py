import json
import unittest
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
REFERENCES = SKILL_ROOT / "references"
SCRIPTS = SKILL_ROOT / "scripts"


class ClientTesterSkillContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        cls.runner = (SCRIPTS / "sanad_conversation_workflow.py").read_text(
            encoding="utf-8"
        )
        cls.adapter = (SCRIPTS / "dual_brain_sanad_ui.py").read_text(
            encoding="utf-8"
        )
        cls.jev_reference = (
            REFERENCES / "jev-conversation-automation.md"
        ).read_text(encoding="utf-8")

    def test_main_skill_is_a_bounded_router(self) -> None:
        self.assertLessEqual(len(self.skill.splitlines()), 100)
        self.assertIn("Non-negotiable invariants", self.skill)
        self.assertIn("Routing table", self.skill)

    def test_canonical_conversation_path_skips_redundant_preflight(self) -> None:
        self.assertIn("Canonical conversation fast path", self.skill)
        self.assertIn("execute the runner immediately", self.skill)
        self.assertIn("Do not run separate `sanad-dev status`", self.skill)
        self.assertIn("do not load the full `jev-dual-brain-automation` skill", self.jev_reference)
        self.assertIn("invoke the canonical runner as the first execution command", self.jev_reference)
        self.assertIn("Do not precede it with `sanad-dev status`", self.jev_reference)
        self.assertIn("do not rerun it automatically", self.jev_reference)

    def test_every_routed_reference_exists(self) -> None:
        names = (
            "automated-testing.md",
            "interactive-ui-testing.md",
            "runtime-and-worktrees.md",
            "connection-switching.md",
            "jev-conversation-automation.md",
            "multi-question-ui.md",
        )
        for name in names:
            self.assertTrue((REFERENCES / name).is_file(), name)
            self.assertIn(f"references/{name}", self.skill)

    def test_client_tester_owns_sanad_runner_and_adapter(self) -> None:
        self.assertTrue((SCRIPTS / "sanad_conversation_workflow.py").is_file())
        self.assertTrue((SCRIPTS / "dual_brain_sanad_ui.py").is_file())
        jev_reference = (REFERENCES / "jev-conversation-automation.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("scripts/sanad_conversation_workflow.py", jev_reference)
        self.assertIn("jev-dual-brain-automation", self.runner)

    def test_routing_evals_cover_every_specialized_reference(self) -> None:
        payload = json.loads(
            (SKILL_ROOT / "evals" / "evals.json").read_text(encoding="utf-8")
        )
        routed = {item["expected_reference"] for item in payload["evals"]}
        self.assertEqual(
            routed,
            {
                "references/automated-testing.md",
                "references/interactive-ui-testing.md",
                "references/runtime-and-worktrees.md",
                "references/connection-switching.md",
                "references/jev-conversation-automation.md",
                "references/multi-question-ui.md",
            },
        )
        conversation = next(item for item in payload["evals"] if item["id"] == 4)
        self.assertEqual(
            conversation["expected_first_command"],
            "python3 .agents/skills/sanad-client-tester/scripts/sanad_conversation_workflow.py",
        )
        self.assertEqual(len(conversation["forbidden_preflight"]), 4)
        self.assertNotIn("additional_skill", conversation)

    def test_sanad_adapter_does_not_plan_goals(self) -> None:
        self.assertNotIn("def execute_goal", self.adapter)
        self.assertNotIn("JevClient", self.adapter)
        self.assertNotIn("time.sleep", self.adapter)


if __name__ == "__main__":
    unittest.main()
