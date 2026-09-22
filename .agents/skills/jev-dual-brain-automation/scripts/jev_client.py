import os
import sys
import json
import time
import urllib.request
from pathlib import Path
from typing import Dict, Any, Tuple, Optional

def load_typesafe_key() -> Optional[str]:
    """
    Safely retrieves the TypeSafe API key from environment variables or local .env.
    Never exposes or logs the key.
    """
    key = os.environ.get("TYPESAFE_API_KEY")
    if key:
        return key.strip().strip('"').strip("'")
    
    # Check possible .env locations relative to current working directory
    candidates = [
        Path(".env"),
        Path("temp/.env"),
        Path("../temp/.env"),
        Path("../../temp/.env")
    ]
    for env_file in candidates:
        if env_file.exists():
            try:
                for line in env_file.read_text().splitlines():
                    line = line.strip()
                    if line.startswith("TYPESAFE_API_KEY="):
                        val = line.split("=", 1)[1].strip().strip('"').strip("'")
                        if val:
                            return val
            except Exception:
                pass
    return None

class JevClient:
    """
    Client for TypeSafe Jev System 1 decision engine.
    Provides sub-second choice classification, probabilistic verification (noul), and item scoring.
    """
    API_URL = "https://api.typesafe.ai/v1/systemone"

    def __init__(self, api_key: Optional[str] = None, model: str = "jev-latest"):
        self.api_key = api_key or load_typesafe_key()
        if not self.api_key:
            raise ValueError("TYPESAFE_API_KEY not found in environment or .env file.")
        self.model = model

    def query(self, state: str, questions: Dict[str, Any], timeout: int = 15) -> Tuple[Dict[str, Any], int]:
        """
        Submits questions to the Jev System 1 endpoint.
        Returns the parsed JSON response and roundtrip latency in milliseconds.
        """
        payload = {
            "state": state,
            "model": self.model,
            "questions": questions
        }
        req = urllib.request.Request(
            self.API_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json"
            }
        )
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        latency_ms = int((time.time() - t0) * 1000)
        return data, latency_ms

    def classify_choice(self, state: str, instruction: str, criteria: Dict[str, str]) -> Tuple[Optional[str], int]:
        """
        Selects the best matching option among criteria candidates.
        """
        questions = {
            "selection": {
                "type": "choice",
                "instructions": instruction,
                "criteria": criteria
            }
        }
        data, latency = self.query(state, questions)
        chosen = data.get("answers", {}).get("selection", {}).get("choice")
        return chosen, latency

    def evaluate_noul(self, state: str, instruction: str) -> Tuple[float, int]:
        """
        Evaluates a probabilistic yes/no verification question (returns 0.0 to 1.0).
        """
        questions = {
            "check": {
                "type": "noul",
                "instructions": instruction
            }
        }
        data, latency = self.query(state, questions)
        score = data.get("answers", {}).get("check", {}).get("noul", 0.0)
        return float(score), latency
