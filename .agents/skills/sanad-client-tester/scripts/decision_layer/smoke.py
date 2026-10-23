"""End-to-end smoke: the real decision model over the curated fixture set.

This is the only code path that spends real model calls. It is deliberately
small and bounded: eight labelled decisions (one call each, sixteen maximum) that
prove the wiring - mode scoping, guard refusal on the P0 trap, and the
irreversible-authorization boundary - without any live runtime.

Run from the repository root so the Jev client can find its key file:

    PYTHONPATH=.agents/skills/sanad-client-tester/scripts \\
      python3 -m decision_layer smoke --trace /tmp/decision-smoke.jsonl --out /tmp/decision-smoke.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .bridge import DecisionPolicy
from .brake import USD_PER_MILLION_INPUT_TOKENS
from .layer import DecisionLayer, DecisionRequest
from .model import DEFAULT_DECISION_TIMEOUT, JevDecisionModel, build_model
from .modes import (
    ASK_USER_CARD,
    CONVERSATION_IDLE,
    MODEL_PICKER,
    PERMISSION_CARD,
    SETTINGS,
)
from .observation import Observation
from .trace import TraceWriter, load_trace, summarize

SKILL_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURES = SKILL_ROOT / "tests/fixtures/snapshots"
DEFAULT_LABELS = SKILL_ROOT / "tests/fixtures/labels.json"

MAX_CALLS = 20
DEFAULT_FLOOR = 0.65

DECLINE_CODES = frozenset({"model_abstained", "model_reobserve"})

# Eight labelled decisions across seven modes. ``expect`` marks the case the guard
# must refuse on purpose: an irreversible delete the phase does not authorize.
# ``forbid`` names an id that must never be admitted, whatever the model answers:
# the P0 empty-field submit, which the extractor no longer even offers.
SMOKE_PLAN: tuple = (
    {
        "fixture": "01-conversation-idle.json",
        "phase": "send_message",
        "expected_mode": CONVERSATION_IDLE,
        "authorize": ("send_message_btn",),
    },
    {
        "fixture": "03-model-picker.json",
        "phase": "choose_model",
        "expected_mode": MODEL_PICKER,
    },
    {
        "fixture": "08-settings-root.json",
        "phase": "navigate_settings",
        "expected_mode": SETTINGS,
    },
    {
        "fixture": "16-ask-user-card.json",
        "phase": "answer_question_1",
        "expected_mode": ASK_USER_CARD,
    },
    {
        # The empty field means the submit is not a candidate at all, so the honest
        # answer is the label's ``abstain`` (or "type first"), never the trap id.
        "fixture": "17-ask-user-custom-input.json",
        "phase": "submit_custom_answer",
        "expected_mode": ASK_USER_CARD,
        "forbid": ("submit_question_answer_btn",),
    },
    {
        "fixture": "18-ask-user-question2.json",
        "phase": "navigate_question",
        "expected_mode": ASK_USER_CARD,
    },
    {
        "fixture": "20-permission-card.json",
        "phase": "approve_once",
        "expected_mode": PERMISSION_CARD,
        "authorize": ("permission_option_once",),
    },
    {
        "fixture": "24-settings-profile.json",
        "phase": "delete_account",
        "expected_mode": SETTINGS,
        "expect": "escalated",
        "expect_reason": "irreversible_not_authorized",
    },
)


def _percentile(values: List[float], fraction: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def _labels(path: Path) -> Dict[str, Dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return {item["snapshot"]: item for item in payload["decisions"]}


def _status(outcome: Any, case: Dict[str, Any], label: Dict[str, Any], correct) -> str:
    if outcome.ok:
        if outcome.admitted.candidate_id in set(case.get("forbid") or ()):
            return "WRONG"
        return "right" if outcome.admitted.candidate_id in correct else "WRONG"
    code = outcome.escalation.reason_code
    expected = case.get("expect")
    if expected == "escalated":
        wanted = case.get("expect_reason")
        if wanted and wanted != code:
            return "unexpected_refusal"
        return "refused_as_designed"
    if correct == {"abstain"} and code in DECLINE_CODES:
        return "right"
    return "escalated"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="decision_layer smoke")
    parser.add_argument("--fixtures", default=str(DEFAULT_FIXTURES))
    parser.add_argument("--labels", default=str(DEFAULT_LABELS))
    parser.add_argument("--out", default=None, help="summary JSON path")
    parser.add_argument("--trace", default=None, help="JSONL trace path")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--floor", type=float, default=DEFAULT_FLOOR)
    parser.add_argument("--timeout", type=float, default=None)
    parser.add_argument("--model", default=None, help="defaults to the real Jev model")
    args = parser.parse_args(argv)

    fixtures = Path(args.fixtures)
    labels = _labels(Path(args.labels))
    plan = SMOKE_PLAN[: args.limit] if args.limit else SMOKE_PLAN
    if len(plan) > MAX_CALLS:
        print(f"refusing to run: {len(plan)} decisions exceeds the {MAX_CALLS} call budget")
        return 2

    if args.model and args.model != "jev":
        model = build_model(args.model)
    else:
        model = JevDecisionModel.from_environment(
            timeout=args.timeout if args.timeout is not None else DEFAULT_DECISION_TIMEOUT
        )

    trace = TraceWriter(Path(args.trace)) if args.trace else None
    layer = DecisionLayer(
        model=model, trace=trace, policy=DecisionPolicy(min_confidence=args.floor)
    )

    results: List[Dict[str, Any]] = []
    for case in plan:
        fixture = case["fixture"]
        label = labels[fixture]
        snapshot = json.loads((fixtures / fixture).read_text(encoding="utf-8"))
        observation = Observation.from_snapshot(snapshot, ref=fixture)
        request = DecisionRequest(
            goal=label["task"],
            phase=case.get("phase", label["phase"]),
            expected_mode=case.get("expected_mode"),
            authorizations=frozenset(case.get("authorize") or ()),
        )
        outcome = layer.decide(observation, request)
        correct = set(label["correct"])
        status = _status(outcome, case, label, correct)
        choice = outcome.choice
        metadata = dict(choice.metadata) if choice is not None else {}
        results.append(
            {
                "fixture": fixture,
                "phase": request.phase,
                "mode": outcome.mode_evidence.mode,
                "mode_detail": outcome.mode_evidence.detail,
                "candidate_count": outcome.candidate_count,
                "selected": choice.choice if choice is not None else None,
                "confidence": choice.confidence if choice is not None else None,
                "verdict": "admitted" if outcome.ok else "escalated",
                "reason_code": outcome.escalation.reason_code
                if outcome.escalation is not None
                else None,
                "admitted_id": outcome.admitted.candidate_id if outcome.ok else None,
                "correct": sorted(correct),
                "status": status,
                "latency_ms": choice.latency_ms if choice is not None else None,
                "input_tokens": metadata.get("input_tokens"),
                "output_tokens": metadata.get("output_tokens"),
                "api_model": choice.model if choice is not None else None,
            }
        )
        print(
            f"{fixture[:32]:34} {results[-1]['mode']:20} "
            f"{(results[-1]['selected'] or '-'):34} "
            f"conf={results[-1]['confidence']} "
            f"{results[-1]['verdict']}/{results[-1]['reason_code'] or '-'} "
            f"{results[-1]['latency_ms']}ms {status}",
            flush=True,
        )

    latencies = [
        float(item["latency_ms"]) for item in results if item["latency_ms"] is not None
    ]
    tokens = sum(int(item["input_tokens"] or 0) for item in results)
    summary = {
        "model": results[0]["api_model"] if results else None,
        "decisions": len(results),
        "calls": sum(1 for item in results if item["selected"] is not None),
        "right": sum(1 for item in results if item["status"] == "right"),
        "wrong": sum(1 for item in results if item["status"] == "WRONG"),
        "refused_as_designed": sum(
            1 for item in results if item["status"] == "refused_as_designed"
        ),
        "other": sum(
            1
            for item in results
            if item["status"] not in {"right", "WRONG", "refused_as_designed"}
        ),
        "admitted": sum(1 for item in results if item["verdict"] == "admitted"),
        "escalated": sum(1 for item in results if item["verdict"] == "escalated"),
        "input_tokens": tokens,
        "estimated_cost_usd": round(tokens * USD_PER_MILLION_INPUT_TOKENS / 1_000_000, 8),
        "latency_ms": {
            "p50": _percentile(latencies, 0.5),
            "p95": _percentile(latencies, 0.95),
            "mean": round(sum(latencies) / len(latencies), 1) if latencies else None,
        },
        "results": results,
    }
    if trace is not None:
        summary["trace"] = str(trace.path)
        summary["trace_summary"] = summarize(load_trace(trace.path))
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(summary, indent=1), encoding="utf-8")

    print(
        f"\n{summary['decisions']} decisions, {summary['admitted']} admitted, "
        f"{summary['escalated']} escalated | right={summary['right']} "
        f"wrong={summary['wrong']} refused_as_designed={summary['refused_as_designed']} "
        f"other={summary['other']} | p50={summary['latency_ms']['p50']}ms "
        f"p95={summary['latency_ms']['p95']}ms | "
        f"~${summary['estimated_cost_usd']:.8f}"
    )
    return 0 if summary["wrong"] == 0 and summary["other"] == 0 else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
