import os
import sys
import re
import time
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Callable, Any

from jev_client import JevClient

class DualBrainBrowser:
    """
    General-purpose browser automation engine combining TypeSafe Jev (System 1)
    with Strong Model escalation (System 2) and automated circuit breaking.
    """

    def __init__(
        self,
        profile_dir: Optional[str] = None,
        headed: bool = True,
        system_2_handler: Optional[Callable[[str, str, Dict[str, Any]], bool]] = None
    ):
        self.profile_dir = profile_dir
        self.headed = headed
        self.system_2_handler = system_2_handler
        self.jev = JevClient()
        self.action_history: List[Dict[str, Any]] = []

    def run_cli(self, args: List[str]) -> Tuple[str, str, int]:
        cmd = ["agent-browser"]
        if self.headed:
            cmd.append("--headed")
        if self.profile_dir:
            cmd.extend(["--profile", self.profile_dir])
        cmd.extend(args)
        proc = subprocess.run(cmd, capture_output=True, text=True)
        return proc.stdout.strip(), proc.stderr.strip(), proc.returncode

    def get_snapshot(self) -> Tuple[str, Dict[str, str]]:
        stdout, _, _ = self.run_cli(["snapshot", "-i"])
        elements = {}
        for line in stdout.splitlines():
            match = re.search(r"ref=(e\d+)", line)
            if match:
                ref = match.group(1)
                desc = line.strip().lstrip("- ").strip()
                elements[ref] = desc
        return stdout, elements

    def detect_circuit_breaker(self) -> Optional[str]:
        """
        Detects repetitive action loops, oscillations, or stuck states.
        Returns the reason string if circuit breaker tripped, else None.
        """
        if len(self.action_history) >= 3:
            recent_targets = [a.get("target") for a in self.action_history[-3:]]
            if len(set(recent_targets)) == 1:
                return f"Stuck clicking same element (@{recent_targets[0]}) repeatedly."
        if len(self.action_history) >= 4:
            recent_targets = [a.get("target") for a in self.action_history[-4:]]
            if len(set(recent_targets)) <= 2:
                return f"Ping-pong oscillation between elements {set(recent_targets)}."
        return None

    def execute_goal(
        self,
        goal: str,
        start_url: Optional[str] = None,
        max_steps: int = 15,
        target_keywords: Optional[List[str]] = None
    ) -> bool:
        """
        Executes an autonomous goal using Jev micro-loop with circuit breaking.
        """
        if start_url:
            print(f"🌐 Navigating to {start_url}...")
            self.run_cli(["open", start_url])
            time.sleep(2)

        step = 1
        while step <= max_steps:
            print(f"\n👉 [Step {step}/{max_steps}] Scanning page state...")
            raw_snapshot, elements = self.get_snapshot()

            # Check Circuit Breaker
            breaker_reason = self.detect_circuit_breaker()
            if breaker_reason:
                print(f"⚠️ [CIRCUIT BREAKER TRIPPED] {breaker_reason}")
                if self.system_2_handler:
                    context = {
                        "goal": goal,
                        "step": step,
                        "history": self.action_history,
                        "elements": elements
                    }
                    handled = self.system_2_handler(breaker_reason, raw_snapshot, context)
                    if handled:
                        print("✅ System 2 resolved obstacle. Re-engaging Jev micro-loop.")
                        self.action_history.clear()
                        step += 1
                        time.sleep(1.5)
                        continue
                print("❌ No System 2 handler or handler failed to resolve obstacle. Aborting.")
                return False

            # Filter candidates for Jev
            candidates = {}
            if target_keywords:
                for ref, desc in elements.items():
                    if any(k.lower() in desc.lower() for k in target_keywords):
                        candidates[ref] = desc[:70]
            if len(candidates) < 2:
                # Fall back to top interactable elements
                candidates = {ref: desc[:70] for ref, desc in list(elements.items())[:8]}

            if not candidates:
                print("⚠️ No interactable candidates found in DOM.")
                break

            state_prompt = (
                f"Goal: {goal}\n"
                f"Step: {step}\n"
                f"Recent Actions: {[a.get('desc') for a in self.action_history[-3:]]}\n"
                f"Candidates:\n" + "\n".join([f"@{k}: {v}" for k, v in candidates.items()])
            )

            # Check goal completion first
            goal_done_prob, _ = self.jev.evaluate_noul(
                state_prompt,
                f"Is the user's ultimate goal ('{goal}') already fully achieved on this screen?"
            )
            if goal_done_prob > 0.85:
                print(f"🎉 Goal achieved! (Confidence: {goal_done_prob:.2f})")
                return True

            # Decide next action
            target, latency = self.jev.classify_choice(
                state_prompt,
                "Which interactive element should be clicked or filled next to make progress toward the goal?",
                candidates
            )

            if not target or target not in candidates:
                print(f"⚠️ Jev did not select a valid candidate.")
                break

            target_desc = candidates[target]
            print(f"⚡ Jev Decision in {latency}ms: @{target} ({target_desc})")

            # Execute action
            is_input = any(kw in target_desc.lower() for kw in ["textbox", "combobox", "input", "search"])
            action_desc = ""
            if is_input and "search" in goal.lower():
                # Extract search term or fill
                query = goal.split()[-1]
                self.run_cli(["fill", f"@{target}", query])
                time.sleep(0.5)
                self.run_cli(["press", "Enter"])
                action_desc = f"fill @{target} '{query}' + Enter"
            else:
                self.run_cli(["click", f"@{target}"])
                action_desc = f"click @{target}"

            self.action_history.append({
                "step": step,
                "target": target,
                "target_desc": target_desc,
                "desc": action_desc
            })

            time.sleep(1.5)
            step += 1

        return False
