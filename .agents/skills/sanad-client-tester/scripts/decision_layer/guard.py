"""The code-owned precondition guard.

B10 measured the reason this module exists: on Sanad screens a wrong action can
be *more* confident than a correct one (``submit`` with an empty answer field at
0.98), so confidence can never be the last gate before an action. The guard is
that gate. It runs twice:

* ``evaluate_pre`` before any model call, on facts about the screen alone, so an
  unusable screen costs nothing and produces a reason code instead of a guess;
* ``evaluate_post`` before dispatch, on the selected candidate's own
  preconditions and on whether the action is irreversible.

A refusal is always converted into an escalation by the caller. The guard never
raises, never dispatches, and never reorders its checks: the first failing rule
is the reported reason, which keeps escalation codes stable and reviewable.

``candidates.extract`` also drops a control whose *snapshot-derived* preconditions
fail, so the model is not offered an action it could not perform. That filter is a
convenience in front of this gate, never a replacement for it: ``evaluate_post``
re-checks every precondition on the live snapshot, and that check is what refuses a
stale table.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping, Optional

from .actions import DETAIL_IS, FIELD_FILLED, FIELD_PRESENT, MODE_IS, rule_for
from .candidates import RESERVED, CandidateTable
from .modes import UNKNOWN

# Stable reason codes. Every code below is also documented in
# docs/qa_maintenance/jev_sanad_ui_automation.md and asserted by the skill tests.
OBSERVATION_NOT_OK = "observation_not_ok"
NOT_SETTLED = "not_settled"
STALE_OBSERVATION = "stale_observation"
UNKNOWN_MODE = "unknown_mode"
MODE_MISMATCH = "mode_mismatch"
DIALOG_BLOCKING = "dialog_blocking"
EMPTY_CANDIDATE_TABLE = "empty_candidate_table"
PHASE_REENTRY = "phase_reentry"
MODEL_UNAVAILABLE = "model_unavailable"
MODEL_CONTRADICTION = "model_contradiction"
MODEL_ABSTAINED = "model_abstained"
MODEL_REOBSERVE = "model_reobserve"
INVALID_TARGET = "invalid_target"
TARGET_ABSENT = "target_absent"
DISABLED_TARGET = "disabled_target"
UNCLASSIFIED_TARGET = "unclassified_target"
PRECONDITION_FAILED = "precondition_failed"
IRREVERSIBLE_NOT_AUTHORIZED = "irreversible_not_authorized"
LOW_CONFIDENCE = "low_confidence"
REPEATED_TARGET = "repeated_target"
OSCILLATION = "oscillation"
NO_TRANSITION = "no_transition"

REASON_CODES = (
    OBSERVATION_NOT_OK,
    NOT_SETTLED,
    STALE_OBSERVATION,
    UNKNOWN_MODE,
    MODE_MISMATCH,
    DIALOG_BLOCKING,
    EMPTY_CANDIDATE_TABLE,
    PHASE_REENTRY,
    MODEL_UNAVAILABLE,
    MODEL_CONTRADICTION,
    MODEL_ABSTAINED,
    MODEL_REOBSERVE,
    INVALID_TARGET,
    TARGET_ABSENT,
    DISABLED_TARGET,
    UNCLASSIFIED_TARGET,
    PRECONDITION_FAILED,
    IRREVERSIBLE_NOT_AUTHORIZED,
    LOW_CONFIDENCE,
    REPEATED_TARGET,
    OSCILLATION,
    NO_TRANSITION,
)


@dataclass(frozen=True)
class Refusal:
    code: str
    detail: str
    evidence: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "reason_code": self.code,
            "detail": self.detail,
            "evidence": dict(self.evidence),
        }


def _expected_mode(request: Any) -> Optional[str]:
    return getattr(request, "expected_mode", None)


def _authorizations(request: Any) -> frozenset:
    return frozenset(getattr(request, "authorizations", ()) or ())


def evaluate_pre(
    observation: Any,
    request: Any,
    mode_evidence: Any,
    table: CandidateTable,
) -> Optional[Refusal]:
    """Screen-level checks that need no model answer."""
    if observation.status != "ok":
        return Refusal(
            OBSERVATION_NOT_OK,
            f"snapshot status is {observation.status!r}",
            {"status": observation.status},
        )
    if observation.settled is False:
        return Refusal(
            NOT_SETTLED,
            "the snapshot was captured while the tree was still changing",
            {"generation": observation.generation},
        )
    if mode_evidence.mode == UNKNOWN:
        return Refusal(
            UNKNOWN_MODE,
            "no declared screen mode matches this snapshot",
            {"element_count": observation.key_count()},
        )

    expected = _expected_mode(request)
    if expected is not None and expected != mode_evidence.mode:
        # An overlay that owns the screen while the phase expects a base surface
        # is a blocker, not a misclassification: report it as one.
        if mode_evidence.is_overlay or mode_evidence.blockers:
            return Refusal(
                DIALOG_BLOCKING,
                "an overlay owns the screen while the phase expects another surface",
                {
                    "expected": expected,
                    "observed": mode_evidence.mode,
                    "blockers": list(mode_evidence.blockers) or [mode_evidence.mode],
                },
            )
        return Refusal(
            MODE_MISMATCH,
            f"expected {expected} but the live screen is {mode_evidence.mode}",
            {"expected": expected, "observed": mode_evidence.mode},
        )
    if mode_evidence.blockers:
        return Refusal(
            DIALOG_BLOCKING,
            "an overlay is present underneath the current surface",
            {"blockers": list(mode_evidence.blockers)},
        )
    if not table.rows:
        return Refusal(
            EMPTY_CANDIDATE_TABLE,
            "no declared control is valid for this mode",
            {"mode": mode_evidence.mode, "dropped": dict(table.dropped)},
        )
    return None


def evaluate_post(
    observation: Any,
    request: Any,
    mode_evidence: Any,
    table: CandidateTable,
    selected_id: Optional[str],
) -> Optional[Refusal]:
    """Candidate-level checks that must pass before dispatch."""
    if selected_id is None:
        return Refusal(INVALID_TARGET, "the model returned no candidate id")
    if selected_id == "abstain":
        return Refusal(MODEL_ABSTAINED, "the model declined to select any candidate")
    if selected_id == "reobserve":
        return Refusal(
            MODEL_REOBSERVE, "the model asked for another observation of the screen"
        )
    if selected_id in RESERVED:
        return Refusal(INVALID_TARGET, f"{selected_id!r} is not an action")

    row = table.row(selected_id)
    if row is None:
        return Refusal(
            INVALID_TARGET,
            "the selected id is not in the current candidate table",
            {"selected": selected_id, "candidate_count": len(table.candidates)},
        )

    resolved = observation.resolve(row.key)
    if resolved is None:
        return Refusal(
            TARGET_ABSENT,
            "the selected control is no longer present in the live snapshot",
            {"key": row.key},
        )
    key, element = resolved
    if element.get("enabled") is False:
        return Refusal(
            DISABLED_TARGET,
            "the selected control is disabled",
            {"key": key},
        )

    rule = rule_for(key)
    if rule is None:
        return Refusal(
            UNCLASSIFIED_TARGET,
            "the selected control has no declared action rule",
            {"key": key},
        )

    for precondition in rule.preconditions:
        refusal = _check_precondition(precondition, observation, mode_evidence)
        if refusal is not None:
            return refusal

    if rule.irreversible and selected_id not in _authorizations(request):
        return Refusal(
            IRREVERSIBLE_NOT_AUTHORIZED,
            f"{rule.name} is irreversible and this phase did not pre-authorize it",
            {
                "reason": rule.reason,
                "authorized": sorted(_authorizations(request)),
                "selected": selected_id,
            },
        )
    return None


def _check_precondition(
    precondition: str, observation: Any, mode_evidence: Any
) -> Optional[Refusal]:
    verb, _, argument = precondition.partition(":")
    if verb == FIELD_FILLED:
        resolved = observation.resolve(argument)
        if resolved is None:
            return Refusal(
                PRECONDITION_FAILED,
                f"{argument} is not present on this screen",
                {"precondition": precondition},
            )
        key, _element = resolved
        filled = observation.is_filled(key)
        if not filled:
            return Refusal(
                PRECONDITION_FAILED,
                f"{key} is empty, so this action would have no effect",
                {"precondition": precondition, "field": key, "filled": bool(filled)},
            )
        return None
    if verb == FIELD_PRESENT:
        resolved = observation.resolve(argument)
        if resolved is None:
            return Refusal(
                PRECONDITION_FAILED,
                f"{argument} is not present on this screen",
                {"precondition": precondition},
            )
        return None
    if verb == DETAIL_IS:
        if mode_evidence.detail != argument:
            return Refusal(
                PRECONDITION_FAILED,
                f"this action belongs to {argument} but the screen is "
                f"{mode_evidence.detail or 'unrefined'}",
                {"precondition": precondition, "detail": mode_evidence.detail},
            )
        return None
    if verb == MODE_IS:
        if mode_evidence.mode != argument:
            return Refusal(
                PRECONDITION_FAILED,
                f"this action belongs to mode {argument}",
                {"precondition": precondition, "mode": mode_evidence.mode},
            )
        return None
    # Unknown precondition verbs fail closed rather than being ignored.
    return Refusal(
        PRECONDITION_FAILED,
        f"undeclared precondition {precondition!r}",
        {"precondition": precondition},
    )
