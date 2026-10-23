"""Deterministic, mode-scoped candidate extraction.

Contract, inherited from the B10 replay and tightened by its own findings:

* candidate ids derive from the snapshot's own widget keys - a model can never
  invent a selector, a coordinate, or a typed value;
* only controls declared in ``actions.py`` for the *current* screen mode are
  offered, so a modal card cannot be decided by a sidebar row and a model list
  is not truncated by conversation chrome;
* a control reporting ``enabled: false`` is dropped: an inert target cannot be
  chosen, and when it was the only correct action the honest answer is
  ``abstain``;
* ``abstain`` and ``reobserve`` are always present and always reserved;
* a control whose **structural** preconditions fail on this snapshot is dropped
  before the model is asked: an un-fillable submit is not a candidate at all, so
  the honest answer becomes ``abstain`` or "type first" instead of an escalation.
  The guard still re-checks every precondition after the model answers, because a
  table can go stale between extraction and dispatch;
* free text longer than ``MAX_TEXT`` is replaced before the state can leave the
  machine, and a text field's value is never emitted - only ``[empty]`` or
  ``[filled]``, because emptiness is decision-relevant and the content is not;
* identical keys get a stable ``#n`` occurrence suffix instead of collapsing;
* pruning is deterministic and independent of dict ordering: tree order decides.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Any, Dict, Iterable, Mapping, Optional, Sequence, Tuple

from .actions import (
    DETAIL_IS,
    FIELD_FILLED,
    FIELD_PRESENT,
    MODE_IS,
    TIER_CHROME,
    ActionRule,
    rule_for,
)
from .modes import UNKNOWN
from .observation import element_filled, resolve_key

MAX_CANDIDATES = 32
MAX_TEXT = 200
MAX_DESCRIPTION = 140
RESERVED: Tuple[str, ...] = ("abstain", "reobserve")
TEXT_FIELD_TYPES = {"TextField", "TextFieldTapRegion"}

_SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"AIza[0-9A-Za-z_\-]{10,}"),
    re.compile(r"ghp_[A-Za-z0-9]{10,}"),
    re.compile(r"Bearer\s+[A-Za-z0-9_\-\.]{10,}"),
)


def _base_type(raw: Any) -> str:
    if not raw:
        return ""
    return str(raw).split("<", 1)[0].strip()


def _clean_text(value: Any) -> str:
    if value is None:
        return ""
    text = " ".join(str(value).split())
    if not text:
        return ""
    if any(pattern.search(text) for pattern in _SECRET_PATTERNS):
        return "<redacted>"
    if len(text) > MAX_TEXT:
        return "<long free text>"
    return text


def _short_id(key: str) -> str:
    """Keep ids stable and readable without losing uniqueness."""
    if ":" in key:
        head, _, tail = key.partition(":")
        if len(head) > 40:
            head = head[:32] + "~" + hashlib.sha1(head.encode("utf-8")).hexdigest()[:6]
        if ":" in tail:
            _, _, tail = tail.partition(":")
        return f"{head}:{tail[-8:]}"
    if len(key) > 64:
        digest = hashlib.sha1(key.encode("utf-8")).hexdigest()[:8]
        return f"{key[:40]}~{digest}"
    return key


@dataclass(frozen=True)
class Candidate:
    id: str
    key: str
    description: str
    action: str
    rule: str
    family: str
    tier: str
    irreversible: bool
    filled: Optional[bool]
    selected: bool
    order: int

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "key": self.key,
            "description": self.description,
            "action": self.action,
            "rule": self.rule,
            "family": self.family,
            "irreversible": self.irreversible,
            "filled": self.filled,
            "selected": self.selected,
        }


@dataclass(frozen=True)
class CandidateTable:
    mode: str
    mode_detail: Optional[str]
    rows: Tuple[Candidate, ...]
    candidates: Mapping[str, str]
    truncated: Tuple[str, ...]
    dropped: Mapping[str, int]
    element_count: int
    pruned: Tuple[str, ...] = ()

    def row(self, candidate_id: str) -> Optional[Candidate]:
        for row in self.rows:
            if row.id == candidate_id:
                return row
        return None

    def keys(self) -> frozenset:
        return frozenset(row.key for row in self.rows)

    def descriptions(self) -> Dict[str, str]:
        return dict(self.candidates)


def _describe(element: Mapping[str, Any], rule: ActionRule) -> Tuple[str, Optional[bool]]:
    widget_type = _base_type(element.get("type"))
    is_text = widget_type in TEXT_FIELD_TYPES
    filled: Optional[bool] = None
    if is_text:
        filled = bool(_clean_text(element.get("text")))
    label_parts = [
        # A TextField's own `text` is entered content and is never a label.
        "" if is_text else _clean_text(element.get("text")),
        _clean_text(element.get("hint")),
        _clean_text(element.get("semantics_label")),
        _clean_text(element.get("tooltip")),
    ]
    label = next((part for part in label_parts if part), "")
    if is_text:
        state = "filled" if filled else "empty"
        description = f"{rule.action}: {label or 'text field'} [{state}]"
    else:
        description = f"{rule.action}: {label}" if label else rule.action
    if len(description) > MAX_DESCRIPTION:
        description = description[: MAX_DESCRIPTION - 3] + "..."
    return description, filled


def _unique_id(key: str, seen: Dict[str, int], used: Dict[str, str]) -> str:
    occurrence = seen.get(key, 0)
    seen[key] = occurrence + 1
    candidate_id = _short_id(key)
    if occurrence:
        candidate_id = f"{candidate_id}#{occurrence + 1}"
    # Two distinct long keys can share a short id; keep them distinct forever.
    if candidate_id in used and used[candidate_id] != key:
        suffix = 2
        while f"{candidate_id}~{suffix}" in used:
            suffix += 1
        candidate_id = f"{candidate_id}~{suffix}"
    used[candidate_id] = key
    return candidate_id


def _prune(
    rows: Sequence[Candidate], budget: int
) -> Tuple[Tuple[Candidate, ...], Tuple[str, ...]]:
    kept = list(rows)
    truncated: list[str] = []

    chrome_families = {row.family for row in kept if row.tier == TIER_CHROME}

    def largest(families: Optional[set], floor: int) -> Optional[str]:
        counts: Dict[str, int] = {}
        for row in kept:
            if families is not None and row.family not in families:
                continue
            counts[row.family] = counts.get(row.family, 0) + 1
        counts = {family: count for family, count in counts.items() if count > floor}
        if not counts:
            return None
        return max(counts.items(), key=lambda pair: (pair[1], pair[0]))[0]

    def drop_from(family: str) -> bool:
        for index in range(len(kept) - 1, -1, -1):
            if kept[index].family == family and not kept[index].selected:
                removed = kept.pop(index)
                truncated.append(removed.id)
                return True
        return False

    while len(kept) > budget:
        target = largest(chrome_families, 1)
        if target is not None and drop_from(target):
            continue
        target = largest(None, 1)
        if target is not None and drop_from(target):
            continue
        if not drop_from(kept[0].family):
            # Nothing unselected is left: fail closed on the oldest route rather
            # than exceed the cap. Flutter renders the newest route last.
            truncated.append(kept.pop(0).id)
    return tuple(kept), tuple(truncated)


def _structural_failure(
    rule: ActionRule, elements: Sequence[Mapping[str, Any]]
) -> Optional[str]:
    """The first snapshot-derived precondition this control cannot satisfy.

    Only preconditions that are facts about the snapshot are evaluated here:
    ``field_filled`` and ``field_present``. ``mode`` and ``detail`` are already
    enforced by the mode-scoped table, and the guard re-checks all four after the
    model answers.
    """
    for precondition in rule.preconditions:
        verb, _, argument = precondition.partition(":")
        if verb == FIELD_FILLED:
            resolved = resolve_key(elements, argument)
            if resolved is None or not element_filled(resolved[1]):
                return precondition
        elif verb == FIELD_PRESENT:
            if resolve_key(elements, argument) is None:
                return precondition
        elif verb not in (DETAIL_IS, MODE_IS):  # pragma: no cover - table is declared
            return precondition
    return None


def extract(
    elements: Iterable[Mapping[str, Any]],
    mode: str,
    mode_detail: Optional[str] = None,
    max_candidates: int = MAX_CANDIDATES,
) -> CandidateTable:
    """Build the closed candidate table for one screen mode."""
    materialized = tuple(elements)
    rows: list[Candidate] = []
    pruned: list[str] = []
    dropped: Dict[str, int] = {
        "no-key": 0,
        "unclassified": 0,
        "out-of-scope": 0,
        "disabled": 0,
        "precondition-failed": 0,
        "unknown-mode": 0,
    }
    seen: Dict[str, int] = {}
    used: Dict[str, str] = {}

    if mode == UNKNOWN:
        dropped["unknown-mode"] = len(materialized)

    for element in materialized:
        if mode == UNKNOWN:
            continue
        key = element.get("key")
        if not isinstance(key, str) or not key:
            dropped["no-key"] += 1
            continue
        rule = rule_for(key)
        if rule is None:
            dropped["unclassified"] += 1
            continue
        if mode not in rule.modes:
            dropped["out-of-scope"] += 1
            continue
        if element.get("enabled") is False:
            dropped["disabled"] += 1
            continue
        if _structural_failure(rule, materialized) is not None:
            dropped["precondition-failed"] += 1
            pruned.append(key)
            continue
        description, filled = _describe(element, rule)
        rows.append(
            Candidate(
                id=_unique_id(key, seen, used),
                key=key,
                description=description,
                action=rule.action,
                rule=rule.name,
                family=rule.family,
                tier=rule.tier,
                irreversible=rule.irreversible,
                filled=filled,
                selected=element.get("selected") is True,
                order=len(rows),
            )
        )

    kept, truncated = _prune(rows, max_candidates - len(RESERVED))
    candidates: Dict[str, str] = {row.id: row.description for row in kept}
    candidates["abstain"] = (
        "none of these candidates is the correct next action for the goal"
    )
    candidates["reobserve"] = (
        "the screen is not settled or the evidence is insufficient; observe again"
    )
    return CandidateTable(
        mode=mode,
        mode_detail=mode_detail,
        rows=kept,
        candidates=candidates,
        truncated=truncated,
        dropped=dropped,
        element_count=len(materialized),
        pruned=tuple(pruned),
    )
