"""The escalation payload and its documented resume contract.

The shape follows ``jev-dual-brain-automation/references/failure_modes_and_recovery.md``:
reason code, goal, phase, screen mode, candidate ids, completed phases, recent
actions, and a snapshot reference. It is bounded, JSON-safe, and free of secrets,
entered values, obscured fields, and unrelated UI content.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping, Optional, Tuple

RESUME_STEPS: Tuple[str, ...] = (
    "read reason_code and detail first; do not re-run the refused action blindly",
    "re-observe the screen and rebuild candidates only after the repair",
    "preserve completed and irreversible-attempted phases; never clear history",
    "re-decide only the next safe, retryable step",
    "a second escalation in the same phase ends the run deterministically",
)


@dataclass(frozen=True)
class EscalationPayload:
    reason_code: str
    detail: str
    goal: str
    phase: str
    mode: str
    mode_detail: Optional[str]
    candidate_ids: Tuple[str, ...]
    selected: Optional[str]
    confidence: Optional[float]
    probability: Optional[float]
    irreversible: bool
    completed_phases: Tuple[str, ...]
    recent_actions: Tuple[Mapping[str, Any], ...]
    snapshot: Mapping[str, Any]
    model: str
    guard: Mapping[str, Any] = field(default_factory=dict)
    mode_evidence: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "reason_code": self.reason_code,
            "detail": self.detail,
            "goal": self.goal,
            "phase": self.phase,
            "screen_mode": self.mode,
            "screen_detail": self.mode_detail,
            "candidate_ids": list(self.candidate_ids),
            "selected": self.selected,
            "confidence": self.confidence,
            "probability": self.probability,
            "irreversible": self.irreversible,
            "completed_phases": list(self.completed_phases),
            "recent_actions": [dict(action) for action in self.recent_actions],
            "snapshot": dict(self.snapshot),
            "model": self.model,
            "guard": dict(self.guard),
            "mode_evidence": dict(self.mode_evidence),
            "resume": list(RESUME_STEPS),
        }
