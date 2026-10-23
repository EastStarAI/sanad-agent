"""The guarded decision step.

Ownership at a glance:

1. ``modes.classify`` names the surface, deterministically.
2. ``candidates.extract`` builds the closed, mode-scoped table.
3. ``guard.evaluate_pre`` refuses an unusable screen *before* any model call.
4. ``DecisionModel.choose`` makes one closed-choice judgment.
5. ``guard.evaluate_post`` enforces the selected action's own preconditions and
   its irreversible-authorization boundary.
6. ``admit_choice`` applies the confidence/selected-probability threshold last, as
   a stall filter - never as the only gate.
7. ``CircuitBreaker`` refuses a repeat or an oscillation before dispatch.
8. The trace records the whole step so it can be replayed.

Execution is not owned here: the layer returns one admitted action and the caller
performs exactly one driver action, then calls ``revalidate`` before dispatch and
``record_action`` afterwards.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping, Optional, Sequence, Tuple

from .bridge import (
    ActionRecord,
    CircuitBreaker,
    DecisionPolicy,
    EscalationCode,
    EscalationRequired,
    admit_choice,
)
from .candidates import CandidateTable, extract
from .escalation import EscalationPayload
from .guard import Refusal, evaluate_post, evaluate_pre
from .model import DecisionContext, DecisionModel, ModelChoice
from .modes import ModeEvidence, classify
from .observation import Observation
from .trace import TraceWriter

_CODE_MAP = {
    EscalationCode.LOW_CONFIDENCE: "low_confidence",
    EscalationCode.INVALID_TARGET: "invalid_target",
    EscalationCode.REPEATED_TARGET: "repeated_target",
    EscalationCode.OSCILLATION: "oscillation",
    EscalationCode.NO_TRANSITION: "no_transition",
    EscalationCode.PHASE_REENTRY: "phase_reentry",
    EscalationCode.TIMEOUT: "timeout",
    EscalationCode.BLOCKED: "blocked",
}

DEFAULT_MIN_CONFIDENCE = 0.65
MAX_RECENT_ACTIONS = 8


@dataclass(frozen=True)
class DecisionRequest:
    """What the scenario declares before a step is decided."""

    goal: str
    phase: str
    expected_mode: Optional[str] = None
    authorizations: frozenset = frozenset()
    instructions: Optional[str] = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "authorizations", frozenset(self.authorizations))


@dataclass(frozen=True)
class AdmittedAction:
    candidate_id: str
    key: str
    action: str
    irreversible: bool
    confidence: Optional[float]
    probability: Optional[float]
    mode: str
    model: str

    def to_dict(self) -> dict:
        return {
            "id": self.candidate_id,
            "key": self.key,
            "action": self.action,
            "irreversible": self.irreversible,
            "confidence": self.confidence,
            "probability": self.probability,
            "mode": self.mode,
            "model": self.model,
        }


@dataclass(frozen=True)
class StepOutcome:
    step: int
    mode_evidence: ModeEvidence
    candidate_count: int
    admitted: Optional[AdmittedAction] = None
    escalation: Optional[EscalationPayload] = None
    choice: Optional[ModelChoice] = None

    @property
    def ok(self) -> bool:
        return self.admitted is not None and self.escalation is None


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class DecisionLayer:
    """Classify, extract, judge, guard, trace - in that order, every step."""

    def __init__(
        self,
        model: DecisionModel,
        *,
        policy: Optional[DecisionPolicy] = None,
        trace: Optional[TraceWriter] = None,
        breaker: Optional[CircuitBreaker] = None,
        completed_phases: Sequence[str] = (),
    ) -> None:
        self.model = model
        self.policy = policy or DecisionPolicy(min_confidence=DEFAULT_MIN_CONFIDENCE)
        self.trace = trace
        self.breaker = breaker or CircuitBreaker()
        self.completed_phases: Tuple[str, ...] = tuple(completed_phases)
        self.recent_actions: Tuple[Mapping[str, Any], ...] = ()
        self._step = 0
        self.outcomes: list = []

    # -- decision ---------------------------------------------------------
    def decide(self, observation: Observation, request: DecisionRequest) -> StepOutcome:
        self._step += 1
        mode_evidence = classify(observation.elements)
        table = extract(observation.elements, mode_evidence.mode, mode_evidence.detail)
        refusal = evaluate_pre(observation, request, mode_evidence, table)
        if refusal is not None:
            return self._escalate(observation, request, mode_evidence, table, refusal, None)

        choice = self.model.choose(self._context(request, mode_evidence, table))
        refusal = evaluate_post(
            observation, request, mode_evidence, table, choice.choice
        )
        if refusal is not None:
            return self._escalate(
                observation, request, mode_evidence, table, refusal, choice
            )

        try:
            admitted = admit_choice(choice, table.candidates, self.policy)
        except EscalationRequired as error:
            return self._escalate(
                observation,
                request,
                mode_evidence,
                table,
                _refusal_from(error),
                choice,
            )

        try:
            self.breaker.check_target(admitted.target)
        except EscalationRequired as error:
            return self._escalate(
                observation,
                request,
                mode_evidence,
                table,
                _refusal_from(error),
                choice,
            )

        row = table.row(admitted.target)
        if row is None:  # pragma: no cover - evaluate_post already proved presence
            return self._escalate(
                observation,
                request,
                mode_evidence,
                table,
                Refusal("invalid_target", "admitted id is not in the table"),
                choice,
            )

        action = AdmittedAction(
            candidate_id=row.id,
            key=row.key,
            action=row.action,
            irreversible=row.irreversible,
            confidence=admitted.confidence,
            probability=admitted.probability,
            mode=mode_evidence.mode,
            model=choice.model,
        )
        outcome = StepOutcome(
            step=self._step,
            mode_evidence=mode_evidence,
            candidate_count=len(table.rows),
            admitted=action,
            choice=choice,
        )
        self.outcomes.append(outcome)
        self._write_trace(observation, request, mode_evidence, table, outcome)
        return outcome

    # -- dispatch-time revalidation --------------------------------------
    def revalidate(
        self,
        admitted: AdmittedAction,
        observation: Observation,
        request: DecisionRequest,
    ) -> StepOutcome:
        """Re-run every guard check against a fresh snapshot before dispatch.

        No model call happens here: an admission is not a license to act on a
        stale screen. A failure is reported with the real refusal code.
        """
        mode_evidence = classify(observation.elements)
        table = extract(observation.elements, mode_evidence.mode, mode_evidence.detail)
        refusal = evaluate_pre(observation, request, mode_evidence, table)
        if refusal is None:
            refusal = evaluate_post(
                observation, request, mode_evidence, table, admitted.candidate_id
            )
        if refusal is not None:
            return self._escalate(
                observation, request, mode_evidence, table, refusal, None
            )
        return StepOutcome(
            step=self._step,
            mode_evidence=mode_evidence,
            candidate_count=len(table.rows),
            admitted=admitted,
        )

    # -- bookkeeping ------------------------------------------------------
    def record_action(
        self,
        phase: str,
        candidate_id: str,
        before_fingerprint: str,
        after_fingerprint: str,
    ) -> Optional[EscalationPayload]:
        """Record one executed action; returns an escalation on a breaker trip."""
        entry = {"phase": phase, "target": candidate_id}
        history = (self.recent_actions + (entry,))[-MAX_RECENT_ACTIONS:]
        self.recent_actions = history
        if phase not in self.completed_phases:
            self.completed_phases = self.completed_phases + (phase,)
        try:
            self.breaker.record(
                ActionRecord(phase, candidate_id, before_fingerprint, after_fingerprint)
            )
        except EscalationRequired as error:
            escalation = _refusal_from(error)
            return EscalationPayload(
                reason_code=escalation.code,
                detail=escalation.detail,
                goal="",
                phase=phase,
                mode="",
                mode_detail=None,
                candidate_ids=(candidate_id,),
                selected=candidate_id,
                confidence=None,
                probability=None,
                irreversible=False,
                completed_phases=self.completed_phases,
                recent_actions=self.recent_actions,
                snapshot={"ref": None, "fingerprint": after_fingerprint[:16]},
                model=self.model.name,
                guard=dict(escalation.evidence),
            )
        return None

    # -- internals --------------------------------------------------------
    def _context(
        self, request: DecisionRequest, mode_evidence: ModeEvidence, table: CandidateTable
    ) -> DecisionContext:
        return DecisionContext(
            goal=request.goal,
            phase=request.phase,
            mode=mode_evidence.mode,
            mode_detail=mode_evidence.detail,
            candidates=table.descriptions(),
            instructions=request.instructions,
            completed_phases=self.completed_phases,
            recent_actions=self.recent_actions,
        )

    def _escalate(
        self,
        observation: Observation,
        request: DecisionRequest,
        mode_evidence: ModeEvidence,
        table: CandidateTable,
        refusal: Refusal,
        choice: Optional[ModelChoice],
    ) -> StepOutcome:
        irreversible = False
        if choice is not None and choice.choice:
            row = table.row(choice.choice)
            irreversible = bool(row.irreversible) if row is not None else False
        payload = EscalationPayload(
            reason_code=refusal.code,
            detail=refusal.detail,
            goal=request.goal,
            phase=request.phase,
            mode=mode_evidence.mode,
            mode_detail=mode_evidence.detail,
            candidate_ids=tuple(table.candidates),
            selected=choice.choice if choice is not None else None,
            confidence=choice.confidence if choice is not None else None,
            probability=(
                choice.probability_for(choice.choice)
                if choice is not None and choice.choice
                else None
            ),
            irreversible=irreversible,
            completed_phases=self.completed_phases,
            recent_actions=self.recent_actions,
            snapshot=observation.reference(),
            model=choice.model if choice is not None else self.model.name,
            guard=dict(refusal.evidence),
            mode_evidence=mode_evidence.to_dict(),
        )
        outcome = StepOutcome(
            step=self._step,
            mode_evidence=mode_evidence,
            candidate_count=len(table.rows),
            escalation=payload,
            choice=choice,
        )
        self.outcomes.append(outcome)
        self._write_trace(observation, request, mode_evidence, table, outcome)
        return outcome

    def _write_trace(
        self,
        observation: Observation,
        request: DecisionRequest,
        mode_evidence: ModeEvidence,
        table: CandidateTable,
        outcome: StepOutcome,
    ) -> None:
        if self.trace is None:
            return
        choice = outcome.choice
        record = {
            "step": outcome.step,
            "at": _now(),
            "goal": request.goal,
            "phase": request.phase,
            "expected_mode": request.expected_mode,
            "mode": mode_evidence.mode,
            "mode_detail": mode_evidence.detail,
            "mode_evidence": mode_evidence.to_dict(),
            "snapshot": observation.reference(),
            "candidate_ids": list(table.candidates),
            "truncated_ids": list(table.truncated),
            "dropped": dict(table.dropped),
            "model": choice.model if choice is not None else self.model.name,
            "model_latency_ms": choice.latency_ms if choice is not None else None,
            "selected": choice.choice if choice is not None else None,
            "confidence": choice.confidence if choice is not None else None,
            "probability": (
                choice.probability_for(choice.choice)
                if choice is not None and choice.choice
                else None
            ),
            "verdict": "admitted" if outcome.admitted else "escalated",
            "reason_code": outcome.escalation.reason_code
            if outcome.escalation is not None
            else None,
            "action": outcome.admitted.to_dict() if outcome.admitted else None,
        }
        self.trace.append(record)


def _refusal_from(error: EscalationRequired) -> Refusal:
    escalation = error.escalation
    return Refusal(
        _CODE_MAP.get(escalation.code, escalation.code.value),
        escalation.reason,
        dict(escalation.context or {}),
    )
