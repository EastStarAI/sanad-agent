import os
import sys
import re
import time
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Callable, Any

from jev_client import JevClient

class DualBrainSanadUI:
    """
    General-purpose Flutter desktop UI automation engine combining TypeSafe Jev (System 1)
    with sanad-dev ui controls and Strong Model escalation (System 2).
    """

    def __init__(self, system_2_handler: Optional[Callable[[str, str, Dict[str, Any]], bool]] = None):
        self.jev = JevClient()
        self.system_2_handler = system_2_handler
        self.action_history: List[Dict[str, Any]] = []

    def run_dev_ui(self, args: List[str]) -> Tuple[str, str, int]:
        cmd = ["sanad-dev", "ui"] + args
        proc = subprocess.run(cmd, capture_output=True, text=True)
        return proc.stdout.strip(), proc.stderr.strip(), proc.returncode

    def get_ui_tree(self) -> Tuple[str, Dict[str, str]]:
        """
        Extracts semantic widgets from the running Flutter client via sanad-dev ui.
        """
        stdout, _, _ = self.run_dev_ui(["tree"])
        elements = {}
        # Parse tree lines
        for line in stdout.splitlines():
            line_str = line.strip()
            # Match widgets with semantic labels or keys
            match = re.search(r'([A-Za-z0-9_]+)\s+\[label="([^"]+)"\]', line_str)
            if match:
                w_id = match.group(1)
                label = match.group(2)
                elements[w_id] = f"{w_id}: {label}"
            else:
                match_id = re.search(r'id=([A-Za-z0-9_\-]+)', line_str)
                if match_id:
                    w_id = match_id.group(1)
                    elements[w_id] = line_str[:60]
        return stdout, elements

    def detect_circuit_breaker(self) -> Optional[str]:
        if len(self.action_history) >= 3:
            recent = [a.get("target") for a in self.action_history[-3:]]
            if len(set(recent)) == 1:
                return f"Stuck tapping same widget ({recent[0]})."
        if len(self.action_history) >= 4:
            recent = [a.get("target") for a in self.action_history[-4:]]
            if len(set(recent)) <= 2:
                return f"Oscillating between widgets {set(recent)}."
        return None

    def execute_goal(
        self,
        goal: str,
        max_steps: int = 10,
        target_labels: Optional[List[str]] = None
    ) -> bool:
        """
        Executes a desktop UI goal autonomously using Jev micro-loop.
        """
        step = 1
        while step <= max_steps:
            print(f"\n👉 [Flutter UI Step {step}/{max_steps}] Reading UI Tree...")
            raw_tree, elements = self.get_ui_tree()

            breaker_reason = self.detect_circuit_breaker()
            if breaker_reason:
                print(f"⚠️ [UI CIRCUIT BREAKER] {breaker_reason}")
                if self.system_2_handler:
                    handled = self.system_2_handler(breaker_reason, raw_tree, {"goal": goal, "history": self.action_history})
                    if handled:
                        print("✅ System 2 resolved UI obstacle. Continuing Jev micro-loop.")
                        self.action_history.clear()
                        step += 1
                        continue
                print("❌ No UI recovery handler available.")
                return False

            candidates = {}
            if target_labels:
                for k, v in elements.items():
                    if any(t.lower() in v.lower() for t in target_labels):
                        candidates[k] = v[:60]
            if len(candidates) < 2:
                candidates = {k: v[:60] for k, v in list(elements.items())[:8]}

            if not candidates:
                print("⚠️ No interactive widgets discovered in UI tree.")
                break

            state_summary = (
                f"Goal: {goal}\n"
                f"Step: {step}\n"
                f"History: {[a.get('desc') for a in self.action_history[-3:]]}\n"
                f"Available Widgets:\n" + "\n".join([f"{k}: {v}" for k, v in candidates.items()])
            )

            # Check goal verification
            prob, _ = self.jev.evaluate_noul(
                state_summary,
                f"Has the UI goal ('{goal}') already been satisfied in the current client state?"
            )
            if prob > 0.85:
                print(f"🎉 UI Goal completed successfully! (Confidence: {prob:.2f})")
                return True

            target, latency = self.jev.classify_choice(
                state_summary,
                "Which Flutter widget should be tapped or interacted with next to progress towards the goal?",
                candidates
            )

            if not target or target not in candidates:
                print("⚠️ Jev did not select a valid widget.")
                break

            desc = candidates[target]
            print(f"⚡ Jev UI Decision in {latency}ms: {target} ({desc})")

            # Execute via sanad-dev ui
            self.run_dev_ui(["tap", target])
            action_desc = f"tap {target} ({desc})"

            self.action_history.append({
                "step": step,
                "target": target,
                "desc": action_desc
            })

            time.sleep(1.5)
            step += 1

        return False
