"""Software-owned workflow primitives for confidence-gated Jev automation."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, Generic, List, Mapping, Optional, Set, TypeVar

from jev_client import JevAnswer

EventT = TypeVar("EventT")


class EscalationCode(str, Enum):
    LOW_CONFIDENCE = "low_confidence"
    INVALID_TARGET = "invalid_target"
    REPEATED_TARGET = "repeated_target"
    OSCILLATION = "oscillation"
    NO_TRANSITION = "no_transition"
    PHASE_REENTRY = "phase_reentry"
    TIMEOUT = "timeout"
    BLOCKED = "blocked"


@dataclass(frozen=True)
class Escalation:
    code: EscalationCode
    reason: str
    context: Mapping[str, Any] = field(default_factory=dict)


class EscalationRequired(RuntimeError):
    def __init__(self, escalation: Escalation):
        super().__init__(escalation.reason)
        self.escalation = escalation


@dataclass(frozen=True)
class DecisionPolicy:
    min_confidence: float = 0.75
    min_selected_probability: float = 0.0


@dataclass(frozen=True)
class ActionDecision:
    target: str
    confidence: float
    probability: Optional[float]


def admit_choice(
    answer: JevAnswer,
    candidates: Mapping[str, Any],
    policy: DecisionPolicy,
) -> ActionDecision:
    """Admit only a valid Choice answer that clears deterministic thresholds."""
    if answer.kind != "choice" or answer.choice not in candidates:
        raise EscalationRequired(
            Escalation(
                EscalationCode.INVALID_TARGET,
                "Jev did not select a valid candidate",
                {"choice": answer.choice, "candidate_count": len(candidates)},
            )
        )
    confidence = answer.confidence
    if confidence is None or confidence < policy.min_confidence:
        raise EscalationRequired(
            Escalation(
                EscalationCode.LOW_CONFIDENCE,
                "Choice confidence is below the action threshold",
                {
                    "choice": answer.choice,
                    "confidence": confidence,
                    "required": policy.min_confidence,
                },
            )
        )
    probability = answer.probability_for(answer.choice)
    if (
        policy.min_selected_probability > 0
        and (probability is None or probability < policy.min_selected_probability)
    ):
        raise EscalationRequired(
            Escalation(
                EscalationCode.LOW_CONFIDENCE,
                "Selected-option probability is below the action threshold",
                {
                    "choice": answer.choice,
                    "probability": probability,
                    "required": policy.min_selected_probability,
                },
            )
        )
    return ActionDecision(answer.choice, confidence, probability)


@dataclass(frozen=True)
class ActionRecord:
    phase: str
    target: str
    before_fingerprint: str
    after_fingerprint: str


class CircuitBreaker:
    """Deterministic detection of repetition, oscillation, and no progression."""

    def __init__(self) -> None:
        self.history: List[ActionRecord] = []

    def check_target(self, target: str) -> None:
        recent = [record.target for record in self.history]
        if len(recent) >= 2 and recent[-2:] == [target, target]:
            self._raise(
                EscalationCode.REPEATED_TARGET,
                "The same target would be acted on three times",
                {"target": target},
            )
        if len(recent) >= 3:
            prospective = recent[-3:] + [target]
            if prospective[0] == prospective[2] and prospective[1] == prospective[3]:
                self._raise(
                    EscalationCode.OSCILLATION,
                    "The workflow is oscillating between two targets",
                    {"targets": prospective[-2:]},
                )

    def record(self, record: ActionRecord) -> None:
        self.history.append(record)
        if record.before_fingerprint == record.after_fingerprint:
            self._raise(
                EscalationCode.NO_TRANSITION,
                "The observed UI did not change after the action",
                {"phase": record.phase, "target": record.target},
            )

    @staticmethod
    def _raise(code: EscalationCode, reason: str, context: Mapping[str, Any]) -> None:
        raise EscalationRequired(Escalation(code, reason, context))


class PhaseLedger:
    """Tracks phase attempts and prevents irreversible replay."""

    def __init__(self) -> None:
        self.completed: Set[str] = set()
        self.irreversible_attempts: Set[str] = set()

    def begin(self, phase: str, irreversible: bool) -> None:
        if phase in self.completed or (
            irreversible and phase in self.irreversible_attempts
        ):
            raise EscalationRequired(
                Escalation(
                    EscalationCode.PHASE_REENTRY,
                    "A completed or irreversible phase cannot be re-entered",
                    {"phase": phase, "irreversible": irreversible},
                )
            )
        if irreversible:
            self.irreversible_attempts.add(phase)

    def complete(self, phase: str) -> None:
        self.completed.add(phase)


class EventWaiter(Generic[EventT]):
    """Waits only when the event source emits; it never polls Jev or the UI."""

    def __init__(
        self,
        next_event: Callable[[float], Optional[EventT]],
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._next_event = next_event
        self._clock = clock

    def until(
        self,
        predicate: Callable[[EventT], bool],
        timeout: float,
    ) -> EventT:
        deadline = self._clock() + timeout
        while True:
            remaining = deadline - self._clock()
            if remaining <= 0:
                raise EscalationRequired(
                    Escalation(EscalationCode.TIMEOUT, "Timed out waiting for an event")
                )
            event = self._next_event(remaining)
            if event is None:
                raise EscalationRequired(
                    Escalation(EscalationCode.TIMEOUT, "Timed out waiting for an event")
                )
            if predicate(event):
                return event


class WorkflowEngine:
    """Executes admitted phases while code retains lifecycle ownership."""

    def __init__(self) -> None:
        self.phases = PhaseLedger()
        self.breaker = CircuitBreaker()

    def execute_phase(
        self,
        *,
        phase: str,
        decision: ActionDecision,
        observe_fingerprint: Callable[[], str],
        execute: Callable[[str], None],
        wait_for_transition: Callable[[str], Optional[str]],
        irreversible: bool = False,
    ) -> ActionRecord:
        self.breaker.check_target(decision.target)
        self.phases.begin(phase, irreversible)
        before = observe_fingerprint()
        execute(decision.target)
        after = wait_for_transition(before)
        if after is None:
            raise EscalationRequired(
                Escalation(
                    EscalationCode.TIMEOUT,
                    "No UI transition arrived before the phase deadline",
                    {"phase": phase, "target": decision.target},
                )
            )
        record = ActionRecord(phase, decision.target, before, after)
        self.breaker.record(record)
        self.phases.complete(phase)
        return record
