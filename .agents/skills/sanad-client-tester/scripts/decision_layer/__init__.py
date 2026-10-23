"""Guarded decision layer for Sanad Client UI automation.

Provider-agnostic and offline-testable: a deterministic extractor and screen-mode
classifier, a code-owned precondition guard that runs before any action, an
explicit irreversible-action authorization boundary, one narrow ``DecisionModel``
judgment per step, a bounded escalation payload, and a replayable JSONL trace.

The confidence gate is deliberately *not* the last line of defence. On Sanad
screens a wrong pick was measured at 0.98 confidence, so the guard's structural
checks - mode, presence, enabled state, field state, authorization - decide
whether an action may be dispatched at all.
"""

from .actions import ACTION_RULES, ActionRule, rule_by_name, rule_for, rules_for_mode
from .brake import (
    ESTIMATED_INPUT_TOKENS_PER_CALL,
    USD_PER_MILLION_INPUT_TOKENS,
    BrakeCharge,
    BudgetBrake,
)
from .candidates import MAX_CANDIDATES, RESERVED, Candidate, CandidateTable, extract
from .escalation import RESUME_STEPS, EscalationPayload
from .guard import REASON_CODES, Refusal
from .layer import DEFAULT_MIN_CONFIDENCE, AdmittedAction, DecisionLayer, DecisionRequest, StepOutcome
from .model import (
    DEFAULT_DECISION_TIMEOUT,
    DecisionContext,
    DecisionModel,
    FakeDecisionModel,
    JevDecisionModel,
    ModelChoice,
    ScriptedDecisionModel,
    build_model,
)
from .modes import KNOWN_MODES, OVERLAY_MODES, UNKNOWN, ModeEvidence, classify
from .observation import Observation
from .trace import TraceWriter, load_trace, replay, summarize

__all__ = [
    "ACTION_RULES",
    "ActionRule",
    "AdmittedAction",
    "BrakeCharge",
    "BudgetBrake",
    "Candidate",
    "CandidateTable",
    "DEFAULT_DECISION_TIMEOUT",
    "DEFAULT_MIN_CONFIDENCE",
    "DecisionContext",
    "DecisionLayer",
    "DecisionModel",
    "DecisionRequest",
    "EscalationPayload",
    "ESTIMATED_INPUT_TOKENS_PER_CALL",
    "FakeDecisionModel",
    "JevDecisionModel",
    "KNOWN_MODES",
    "MAX_CANDIDATES",
    "ModeEvidence",
    "ModelChoice",
    "OVERLAY_MODES",
    "Observation",
    "REASON_CODES",
    "RESERVED",
    "RESUME_STEPS",
    "Refusal",
    "ScriptedDecisionModel",
    "StepOutcome",
    "TraceWriter",
    "UNKNOWN",
    "USD_PER_MILLION_INPUT_TOKENS",
    "build_model",
    "classify",
    "extract",
    "load_trace",
    "replay",
    "rule_by_name",
    "rule_for",
    "rules_for_mode",
    "summarize",
]
