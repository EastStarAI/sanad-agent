"""Thin agent-browser adapter for the software-owned decision workflow."""

from __future__ import annotations

import hashlib
import re
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


@dataclass(frozen=True)
class BrowserObservation:
    raw: str
    candidates: Dict[str, str]
    fingerprint: str


class BrowserAdapter:
    """Observes and executes exact browser actions; it does not plan goals."""

    def __init__(self, profile_dir: Optional[str] = None, headed: bool = True):
        self.profile_dir = profile_dir
        self.headed = headed

    def run_cli(self, args: List[str]) -> Tuple[str, str, int]:
        command = ["agent-browser"]
        if self.headed:
            command.append("--headed")
        if self.profile_dir:
            command.extend(["--profile", self.profile_dir])
        command.extend(args)
        process = subprocess.run(command, capture_output=True, text=True, check=False)
        return process.stdout.strip(), process.stderr.strip(), process.returncode

    def observe(self) -> BrowserObservation:
        stdout, stderr, return_code = self.run_cli(["snapshot", "-i"])
        if return_code != 0:
            raise RuntimeError(stderr or "agent-browser snapshot failed")
        candidates: Dict[str, str] = {}
        for line in stdout.splitlines():
            match = re.search(r"ref=(e\d+)", line)
            if match:
                candidates[match.group(1)] = line.strip().lstrip("- ").strip()
        fingerprint = hashlib.sha256(stdout.encode("utf-8")).hexdigest()
        return BrowserObservation(stdout, candidates, fingerprint)

    def open(self, url: str) -> None:
        self._require_success(["open", url])

    def click(self, target: str) -> None:
        self._require_success(["click", f"@{target}"])

    def fill(self, target: str, value: str) -> None:
        self._require_success(["fill", f"@{target}", value])

    def press(self, key: str) -> None:
        self._require_success(["press", key])

    def _require_success(self, args: List[str]) -> None:
        _, stderr, return_code = self.run_cli(args)
        if return_code != 0:
            raise RuntimeError(stderr or f"agent-browser {args[0]} failed")


# Backward-compatible name; orchestration now belongs to workflow_engine.py.
DualBrainBrowser = BrowserAdapter
