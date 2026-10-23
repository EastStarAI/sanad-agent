"""Command line entry point for the guarded decision layer.

Two commands, both offline by default:

* ``decide`` - decide one captured snapshot. With ``--explain`` it prints the mode
  and the closed candidate table and makes no model call at all, which is the
  cheapest way to read a screen before paying for a judgment.
* ``smoke`` - replay the curated fixture set through a real model and write a
  trace plus a summary.

Run from the repository root:

    PYTHONPATH=.agents/skills/sanad-client-tester/scripts python3 -m decision_layer decide --help
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional, Sequence

from .bridge import DecisionPolicy
from .candidates import extract
from .layer import DEFAULT_MIN_CONFIDENCE, DecisionLayer, DecisionRequest
from .model import build_model
from .modes import classify
from .observation import Observation
from .trace import TraceWriter

EXIT_ADMITTED = 0
EXIT_ESCALATED = 3


def _observation(path: Path) -> Observation:
    snapshot = json.loads(Path(path).read_text(encoding="utf-8"))
    return Observation.from_snapshot(snapshot, ref=str(path))


def _explain(observation: Observation, as_json: bool) -> int:
    mode_evidence = classify(observation.elements)
    table = extract(observation.elements, mode_evidence.mode, mode_evidence.detail)
    if as_json:
        print(
            json.dumps(
                {
                    "mode": mode_evidence.to_dict(),
                    "candidates": table.descriptions(),
                    "truncated_ids": list(table.truncated),
                    "dropped": dict(table.dropped),
                    "snapshot": observation.reference(),
                },
                indent=1,
            )
        )
        return EXIT_ADMITTED
    print(f"mode: {mode_evidence.mode} ({mode_evidence.detail or 'no detail'})")
    print(f"evidence: {', '.join(mode_evidence.matched) or 'none'}")
    if mode_evidence.blockers:
        print(f"blockers: {', '.join(mode_evidence.blockers)}")
    print(f"candidates ({len(table.rows)}), dropped={dict(table.dropped)}")
    for candidate_id, description in table.candidates.items():
        print(f"  {candidate_id:52} {description}")
    if table.truncated:
        print(f"truncated by the cap: {', '.join(table.truncated)}")
    return EXIT_ADMITTED


def _decide(args: argparse.Namespace) -> int:
    observation = _observation(Path(args.snapshot))
    if args.explain:
        return _explain(observation, args.json)

    model = build_model(args.model)

    trace = TraceWriter(Path(args.trace)) if args.trace else None
    layer = DecisionLayer(
        model=model,
        trace=trace,
        policy=_policy(args.floor),
    )
    request = DecisionRequest(
        goal=args.goal,
        phase=args.phase,
        expected_mode=args.expect_mode,
        authorizations=frozenset(args.authorize or ()),
        instructions=args.instructions,
    )
    outcome = layer.decide(observation, request)
    payload = (
        {"verdict": "admitted", "action": outcome.admitted.to_dict()}
        if outcome.ok
        else {"verdict": "escalated", "escalation": outcome.escalation.to_dict()}
    )
    if args.json:
        print(json.dumps(payload, indent=1))
    elif outcome.ok:
        action = outcome.admitted
        print(
            f"admitted {action.candidate_id} ({action.action} {action.key}) "
            f"mode={action.mode} confidence={action.confidence}"
        )
    else:
        escalation = outcome.escalation
        print(
            f"escalated {escalation.reason_code}: {escalation.detail} "
            f"(mode={escalation.mode}, selected={escalation.selected})"
        )
    return EXIT_ADMITTED if outcome.ok else EXIT_ESCALATED


def _policy(floor: Optional[float]) -> DecisionPolicy:
    return DecisionPolicy(
        min_confidence=DEFAULT_MIN_CONFIDENCE if floor is None else floor
    )


def _smoke(args: argparse.Namespace) -> int:
    from .smoke import main as smoke_main

    forwarded: list = []
    if args.fixtures:
        forwarded += ["--fixtures", args.fixtures]
    if args.labels:
        forwarded += ["--labels", args.labels]
    if args.out:
        forwarded += ["--out", args.out]
    if args.trace:
        forwarded += ["--trace", args.trace]
    if args.limit:
        forwarded += ["--limit", str(args.limit)]
    if args.floor is not None:
        forwarded += ["--floor", str(args.floor)]
    if args.model:
        forwarded += ["--model", args.model]
    return smoke_main(forwarded)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="decision_layer",
        description="Guarded, provider-agnostic UI decision layer for Sanad Client tests.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    decide = subparsers.add_parser("decide", help="decide one captured snapshot")
    decide.add_argument("--snapshot", required=True)
    decide.add_argument("--goal", required=True)
    decide.add_argument("--phase", required=True)
    decide.add_argument("--expect-mode", default=None)
    decide.add_argument(
        "--authorize",
        action="append",
        default=[],
        help="candidate id pre-authorized for this phase (repeatable)",
    )
    decide.add_argument("--instructions", default=None)
    decide.add_argument(
        "--model",
        default="jev",
        help="jev | fake:<candidate-id>:<confidence> | scripted:<phase>=<id>@<conf>",
    )
    decide.add_argument("--floor", type=float, default=None)
    decide.add_argument("--trace", default=None)
    decide.add_argument("--explain", action="store_true", help="print mode+table only")
    decide.add_argument("--json", action="store_true")
    decide.set_defaults(func=_decide)

    smoke = subparsers.add_parser("smoke", help="replay the fixture set end to end")
    smoke.add_argument("--fixtures", default=None)
    smoke.add_argument("--labels", default=None)
    smoke.add_argument("--out", default=None)
    smoke.add_argument("--trace", default=None)
    smoke.add_argument("--limit", type=int, default=None)
    smoke.add_argument("--floor", type=float, default=None)
    smoke.add_argument("--model", default=None)
    smoke.set_defaults(func=_smoke)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
