"""JSONL step trace: every decision is replayable without the model.

One line per decision, written as soon as the decision is final. A line carries
the snapshot reference, the classified mode with its evidence, the closed
candidate ids (and the ids the cap removed), the model's answer, the guard
verdict, and the admitted action. Nothing in a trace can carry a field value, an
entered text, or a secret.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Tuple

REQUIRED_FIELDS: Tuple[str, ...] = (
    "step",
    "at",
    "phase",
    "goal",
    "mode",
    "snapshot",
    "candidate_ids",
    "model",
    "verdict",
)
VERDICTS = ("admitted", "escalated")


def _validate(record: Mapping[str, Any]) -> None:
    missing = [field for field in REQUIRED_FIELDS if field not in record]
    if missing:
        raise ValueError(f"trace record is missing {missing}")
    if record["verdict"] not in VERDICTS:
        raise ValueError(f"unknown verdict {record['verdict']!r}")
    if not record["candidate_ids"]:
        raise ValueError("trace record has no candidate ids")
    if record["verdict"] == "admitted" and not record.get("action"):
        raise ValueError("an admitted record must carry its action")
    if record["verdict"] == "escalated" and not record.get("reason_code"):
        raise ValueError("an escalated record must carry its reason code")


class TraceWriter:
    """Append-only JSONL writer; deterministic bytes for a given record."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text("", encoding="utf-8")

    def append(self, record: Mapping[str, Any]) -> Dict[str, Any]:
        materialized = dict(record)
        _validate(materialized)
        line = json.dumps(materialized, sort_keys=True, ensure_ascii=False)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
        return materialized


def load_trace(path: Path) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        record = json.loads(raw)
        _validate(record)
        records.append(record)
    return records


def replay(path: Path) -> List[Dict[str, Any]]:
    """Reconstruct the decision sequence from a trace, without any model.

    Each returned step restates what a reviewer needs to re-judge the decision:
    the mode, the candidate table (ids and how many were truncated), the model's
    answer, and the verdict.
    """
    steps: List[Dict[str, Any]] = []
    previous = 0
    for record in load_trace(path):
        step = record["step"]
        if step != previous + 1:
            raise ValueError(f"trace steps are not contiguous at {step}")
        previous = step
        steps.append(
            {
                "step": step,
                "phase": record["phase"],
                "mode": record["mode"],
                "mode_detail": record.get("mode_detail"),
                "candidate_ids": list(record["candidate_ids"]),
                "truncated_ids": list(record.get("truncated_ids") or ()),
                "selected": record.get("selected"),
                "confidence": record.get("confidence"),
                "verdict": record["verdict"],
                "reason_code": record.get("reason_code"),
                "action": record.get("action"),
            }
        )
    return steps


def summarize(records: Iterable[Mapping[str, Any]]) -> Dict[str, Any]:
    materialized = list(records)
    admitted = [record for record in materialized if record["verdict"] == "admitted"]
    escalated = [record for record in materialized if record["verdict"] == "escalated"]
    def _percentile(values: List[float], fraction: float) -> float | None:
        if not values:
            return None
        ordered = sorted(values)
        index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
        return ordered[index]

    latencies = [
        float(record["model_latency_ms"])
        for record in materialized
        if record.get("model_latency_ms") is not None
    ]
    return {
        "steps": len(materialized),
        "admitted": len(admitted),
        "escalated": len(escalated),
        "escalation_rate": round(len(escalated) / len(materialized), 4)
        if materialized
        else 0.0,
        "irreversible_admitted": sum(
            1 for record in admitted if (record.get("action") or {}).get("irreversible")
        ),
        "latency_ms": {
            "p50": _percentile(latencies, 0.5),
            "p95": _percentile(latencies, 0.95),
            "mean": round(sum(latencies) / len(latencies), 1) if latencies else None,
            "samples": len(latencies),
        },
    }
