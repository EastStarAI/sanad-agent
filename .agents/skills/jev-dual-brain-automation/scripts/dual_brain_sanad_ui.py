"""Thin sanad-dev UI adapter for the software-owned decision workflow."""

from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import dataclass
from typing import Any, Dict, List, Tuple


@dataclass(frozen=True)
class SanadObservation:
    elements: List[Dict[str, Any]]
    candidates: Dict[str, str]
    fingerprint: str


class SanadUIAdapter:
    """Observes keyed widgets and performs exact actions; it does not plan goals."""

    def run_dev_ui(self, args: List[str]) -> Tuple[str, str, int]:
        process = subprocess.run(
            ["sanad-dev", "ui", *args],
            capture_output=True,
            text=True,
            check=False,
        )
        return process.stdout.strip(), process.stderr.strip(), process.returncode

    def observe(self, *, interactive_only: bool = True) -> SanadObservation:
        args = ["snapshot", "--compact", "--json"]
        if interactive_only:
            args.append("--interactive")
        stdout, stderr, return_code = self.run_dev_ui(args)
        if return_code != 0:
            raise RuntimeError(stderr or "sanad-dev ui snapshot failed")
        try:
            payload = json.loads(stdout)
            elements = payload["elements"]
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            raise RuntimeError("sanad-dev ui returned malformed JSON") from error
        if not isinstance(elements, list):
            raise RuntimeError("sanad-dev ui elements must be a list")

        candidates: Dict[str, str] = {}
        for element in elements:
            if not isinstance(element, dict) or not element.get("key"):
                continue
            key = str(element["key"])
            summary_parts = [
                str(element[field])
                for field in ("type", "text", "hint", "tooltip", "semantics_label")
                if element.get(field)
            ]
            candidates[key] = " | ".join(summary_parts)
        canonical = json.dumps(elements, sort_keys=True, separators=(",", ":"))
        fingerprint = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        return SanadObservation(elements, candidates, fingerprint)

    def tap(self, key: str) -> None:
        self._require_success(["tap", "--key", key, "--json"])

    def enter_text(self, key: str, value: str) -> None:
        self._require_success(
            ["enter-text", "--key", key, "--text", value, "--json"]
        )

    def find(self, key: str) -> Dict[str, Any]:
        stdout = self._require_success(["find", "--key", key, "--json"])
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("sanad-dev ui find returned malformed JSON") from error

    def _require_success(self, args: List[str]) -> str:
        stdout, stderr, return_code = self.run_dev_ui(args)
        if return_code != 0:
            raise RuntimeError(stderr or f"sanad-dev ui {args[0]} failed")
        return stdout


# Backward-compatible name; orchestration now belongs to workflow_engine.py.
DualBrainSanadUI = SanadUIAdapter
