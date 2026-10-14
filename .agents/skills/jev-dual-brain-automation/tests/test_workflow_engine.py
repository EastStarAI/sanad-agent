import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from jev_client import JevAnswer  # noqa: E402
from workflow_engine import (  # noqa: E402
    ActionDecision,
    ActionRecord,
    CircuitBreaker,
    DecisionPolicy,
    EscalationCode,
    EscalationRequired,
    EventWaiter,
    WorkflowEngine,
    admit_choice,
)


class WorkflowEngineTest(unittest.TestCase):
    def test_choice_requires_full_confidence_gate(self):
        answer = JevAnswer(
            kind="choice",
            choice="send",
            probabilities={"send": 0.91, "wait": 0.09},
            confidence=0.69,
            raw={},
        )
        with self.assertRaises(EscalationRequired) as caught:
            admit_choice(answer, {"send": "Send", "wait": "Wait"}, DecisionPolicy(0.8))
        self.assertEqual(caught.exception.escalation.code, EscalationCode.LOW_CONFIDENCE)

    def test_choice_preserves_probability_and_confidence(self):
        answer = JevAnswer(
            kind="choice",
            choice="send",
            probabilities={"send": 0.94, "wait": 0.06},
            confidence=0.9,
            raw={},
        )
        decision = admit_choice(
            answer,
            {"send": "Send", "wait": "Wait"},
            DecisionPolicy(min_confidence=0.8, min_selected_probability=0.9),
        )
        self.assertEqual(decision, ActionDecision("send", 0.9, 0.94))

    def test_irreversible_phase_executes_only_once(self):
        engine = WorkflowEngine()
        calls = []
        decision = ActionDecision("send", 0.95, 0.98)
        engine.execute_phase(
            phase="send_message",
            decision=decision,
            observe_fingerprint=lambda: "draft",
            execute=lambda target: calls.append(target),
            wait_for_transition=lambda _before: "sent",
            irreversible=True,
        )
        with self.assertRaises(EscalationRequired) as caught:
            engine.execute_phase(
                phase="send_message",
                decision=decision,
                observe_fingerprint=lambda: "sent",
                execute=lambda target: calls.append(target),
                wait_for_transition=lambda _before: "sent-again",
                irreversible=True,
            )
        self.assertEqual(caught.exception.escalation.code, EscalationCode.PHASE_REENTRY)
        self.assertEqual(calls, ["send"])

    def test_no_transition_fails_closed(self):
        engine = WorkflowEngine()
        with self.assertRaises(EscalationRequired) as caught:
            engine.execute_phase(
                phase="open_settings",
                decision=ActionDecision("settings", 0.9, 0.9),
                observe_fingerprint=lambda: "same",
                execute=lambda _target: None,
                wait_for_transition=lambda _before: "same",
            )
        self.assertEqual(caught.exception.escalation.code, EscalationCode.NO_TRANSITION)

    def test_repetition_and_oscillation_trip_before_action(self):
        repeat = CircuitBreaker()
        repeat.history.extend(
            [
                ActionRecord("one", "a", "1", "2"),
                ActionRecord("two", "a", "2", "3"),
            ]
        )
        with self.assertRaises(EscalationRequired) as caught:
            repeat.check_target("a")
        self.assertEqual(caught.exception.escalation.code, EscalationCode.REPEATED_TARGET)

        oscillation = CircuitBreaker()
        oscillation.history.extend(
            [
                ActionRecord("one", "a", "1", "2"),
                ActionRecord("two", "b", "2", "3"),
                ActionRecord("three", "a", "3", "4"),
            ]
        )
        with self.assertRaises(EscalationRequired) as caught:
            oscillation.check_target("b")
        self.assertEqual(caught.exception.escalation.code, EscalationCode.OSCILLATION)

    def test_event_waiter_consumes_events_without_model_or_ui_polling(self):
        events = iter([{"status": "running"}, {"status": "completed"}])
        waits = []

        def next_event(timeout):
            waits.append(timeout)
            return next(events, None)

        event = EventWaiter(next_event).until(
            lambda item: item["status"] == "completed", timeout=1
        )
        self.assertEqual(event["status"], "completed")
        self.assertEqual(len(waits), 2)


if __name__ == "__main__":
    unittest.main()
