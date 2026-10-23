"""Access to the reusable Jev workflow primitives owned by the Jev skill.

The decision layer reuses four tested primitives instead of re-implementing them:

* ``admit_choice`` - the confidence/selected-probability admission gate;
* ``CircuitBreaker`` - repeat, oscillation, and no-transition detection;
* ``EventWaiter`` - event-driven waiting with one deadline;
* ``DecisionPolicy`` - the threshold value object.

Only this module knows where the Jev skill lives, so the guard, the extractor,
and the mode classifier never import Jev concepts.
"""

from __future__ import annotations

import sys
from pathlib import Path


def find_repo_root(start: Path) -> Path:
    for candidate in start.resolve().parents:
        if (candidate / "AGENTS.md").is_file() and (candidate / ".agents").is_dir():
            return candidate
    raise RuntimeError("Could not locate the Sanad repository root")


REPO_ROOT = find_repo_root(Path(__file__))
JEV_SCRIPTS = REPO_ROOT / ".agents/skills/jev-dual-brain-automation/scripts"
if str(JEV_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(JEV_SCRIPTS))

from jev_client import JevAnswer, JevClient, JevResponse  # noqa: E402
from workflow_engine import (  # noqa: E402
    ActionRecord,
    CircuitBreaker,
    DecisionPolicy,
    Escalation,
    EscalationCode,
    EscalationRequired,
    EventWaiter,
    PhaseLedger,
    admit_choice,
)

__all__ = [
    "ActionRecord",
    "CircuitBreaker",
    "DecisionPolicy",
    "Escalation",
    "EscalationCode",
    "EscalationRequired",
    "EventWaiter",
    "JevAnswer",
    "JevClient",
    "JevResponse",
    "PhaseLedger",
    "admit_choice",
]
