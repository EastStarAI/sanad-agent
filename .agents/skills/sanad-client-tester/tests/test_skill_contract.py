import json
import sys
import unittest
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
REFERENCES = SKILL_ROOT / "references"
SCRIPTS = SKILL_ROOT / "scripts"
REPO_ROOT = SKILL_ROOT.parents[2]
DOCS_PAGE = REPO_ROOT / "docs/qa_maintenance/jev_sanad_ui_automation.md"

sys.path.insert(0, str(SCRIPTS))

from decision_layer.guard import REASON_CODES  # noqa: E402

ROUTED_REFERENCES = {
    "references/automated-testing.md",
    "references/interactive-ui-testing.md",
    "references/runtime-and-worktrees.md",
    "references/connection-switching.md",
    "references/jev-conversation-automation.md",
    "references/multi-question-ui.md",
    "references/decision-layer-routing.md",
}


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
        cls.routing_reference = (
            REFERENCES / "decision-layer-routing.md"
        ).read_text(encoding="utf-8")
        cls.docs_page = DOCS_PAGE.read_text(encoding="utf-8")

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

    def test_decision_layer_routing_rule_is_published(self) -> None:
        self.assertIn("Decision-layer routing rule", self.skill)
        self.assertIn("USE the decision layer", self.skill)
        self.assertIn("KEEP the agent", self.skill)
        self.assertIn("references/decision-layer-routing.md", self.skill)
        for required in (
            "navigation between known destinations",
            "picking one listed option",
            "reversible dialog",
            "fixed form flows",
            "semantic correctness",
            "unknown or unclassifiable screens",
            "free text",
            "diagnosing a failure",
            "irreversible step",
        ):
            self.assertIn(required.lower(), self.routing_reference.lower())

    def test_routing_reference_covers_cost_escalation_and_resume(self) -> None:
        for required in (
            "p50 342 ms",
            "$0.00006",
            "Reading an escalation",
            "Resume",
            "Kill criteria",
            "Irreversible actions",
            "Guard rules",
            "Screen-mode keyset",
        ):
            self.assertIn(required, self.routing_reference)
        self.assertIn("4.5–5.5 s", self.routing_reference)

    def test_every_routed_reference_exists(self) -> None:
        names = (
            "automated-testing.md",
            "interactive-ui-testing.md",
            "runtime-and-worktrees.md",
            "connection-switching.md",
            "jev-conversation-automation.md",
            "multi-question-ui.md",
            "decision-layer-routing.md",
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
        self.assertEqual(routed, ROUTED_REFERENCES)
        conversation = next(item for item in payload["evals"] if item["id"] == 4)
        self.assertEqual(
            conversation["expected_first_command"],
            "python3 .agents/skills/sanad-client-tester/scripts/sanad_conversation_workflow.py",
        )
        self.assertEqual(len(conversation["forbidden_preflight"]), 4)
        self.assertNotIn("additional_skill", conversation)
        decision_layer = next(item for item in payload["evals"] if item["id"] == 7)
        self.assertEqual(
            decision_layer["expected_reference"], "references/decision-layer-routing.md"
        )

    def test_sanad_adapter_does_not_plan_goals(self) -> None:
        self.assertNotIn("def execute_goal", self.adapter)
        self.assertNotIn("JevClient", self.adapter)
        self.assertNotIn("time.sleep", self.adapter)

    def test_documented_guard_codes_match_the_code(self) -> None:
        for code in REASON_CODES:
            self.assertIn(code, self.docs_page, f"{code} is undocumented")
            self.assertIn(code, self.routing_reference, f"{code} is undocumented")

    def test_hybrid_docs_own_guard_escalation_and_kill_criteria(self) -> None:
        for required in (
            "confidence does not bound",
            "irreversible_not_authorized",
            "Resume contract",
            "Kill criteria",
            "15 %",
            "6 s",
            "decision_layer/",
        ):
            self.assertIn(required, self.docs_page)

    def test_stale_temp_forwarder_claim_is_gone(self) -> None:
        self.assertNotIn("jev_sanad_conversation_runner", self.docs_page)
        self.assertNotIn("jev_sanad_conversation_runner", self.jev_reference)
        self.assertNotIn("compatibility forwarder", self.docs_page)


if __name__ == "__main__":
    unittest.main()
