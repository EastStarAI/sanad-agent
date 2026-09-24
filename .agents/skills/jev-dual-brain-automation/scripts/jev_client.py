"""Minimal typed client for the TypeSafe System One HTTP API."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Tuple, Union

JsonValue = Union[str, int, float, bool, None, Dict[str, Any], list[Any]]


def load_typesafe_key() -> Optional[str]:
    """Load the API key without logging or returning its source path."""
    key = os.environ.get("TYPESAFE_API_KEY")
    if key:
        return key.strip().strip('"').strip("'")

    for env_file in (
        Path(".env"),
        Path("temp/.env"),
        Path("../temp/.env"),
        Path("../../temp/.env"),
    ):
        if not env_file.is_file():
            continue
        try:
            for raw_line in env_file.read_text(encoding="utf-8").splitlines():
                line = raw_line.strip()
                if line.startswith("TYPESAFE_API_KEY="):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if value:
                        return value
        except OSError:
            continue
    return None


@dataclass(frozen=True)
class JevAnswer:
    """One complete typed answer, including uncertainty evidence."""

    kind: str
    choice: Optional[str] = None
    score: Optional[float] = None
    noul: Optional[float] = None
    probabilities: Any = None
    confidence: Optional[float] = None
    legend: Any = None
    raw: Mapping[str, Any] = None  # type: ignore[assignment]

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> "JevAnswer":
        if "choice" in payload:
            kind = "choice"
        elif "score" in payload:
            kind = "score"
        elif "noul" in payload:
            kind = "noul"
        else:
            raise ValueError("System One answer has no recognized typed value")
        return cls(
            kind=kind,
            choice=str(payload["choice"]) if "choice" in payload else None,
            score=float(payload["score"]) if "score" in payload else None,
            noul=float(payload["noul"]) if "noul" in payload else None,
            probabilities=payload.get("probabilities"),
            confidence=(
                float(payload["confidence"])
                if payload.get("confidence") is not None
                else None
            ),
            legend=payload.get("legend"),
            raw=dict(payload),
        )

    def probability_for(self, option: str) -> Optional[float]:
        probabilities = self.probabilities
        if isinstance(probabilities, Mapping):
            value = probabilities.get(option)
            return float(value) if value is not None else None
        return None


@dataclass(frozen=True)
class JevResponse:
    answers: Mapping[str, JevAnswer]
    latency_ms: int
    raw: Mapping[str, Any]

    def answer(self, question_id: str, expected_kind: Optional[str] = None) -> JevAnswer:
        try:
            answer = self.answers[question_id]
        except KeyError as error:
            raise KeyError(f"Missing System One answer: {question_id}") from error
        if expected_kind is not None and answer.kind != expected_kind:
            raise ValueError(
                f"Answer {question_id!r} is {answer.kind}, expected {expected_kind}"
            )
        return answer


class JevClient:
    """Typed HTTP client; workflow and safety decisions remain caller-owned."""

    API_URL = "https://api.typesafe.ai/v1/systemone"

    def __init__(self, api_key: Optional[str] = None, model: str = "jev-latest"):
        self.api_key = api_key or load_typesafe_key()
        if not self.api_key:
            raise ValueError("TYPESAFE_API_KEY not found in environment or local .env")
        self.model = model

    def ask(
        self,
        state: JsonValue,
        questions: Mapping[str, Mapping[str, Any]],
        timeout: float = 15,
    ) -> JevResponse:
        """Evaluate independent typed questions against one structured state."""
        if not questions:
            raise ValueError("At least one System One question is required")
        payload = {"state": state, "model": self.model, "questions": questions}
        request = urllib.request.Request(
            self.API_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError) as error:
            raise RuntimeError("System One request failed") from error
        latency_ms = round((time.monotonic() - started) * 1000)

        raw_answers = raw.get("answers")
        if not isinstance(raw_answers, Mapping):
            raise ValueError("System One response has no answers object")
        answers = {
            str(question_id): JevAnswer.from_payload(answer)
            for question_id, answer in raw_answers.items()
            if isinstance(answer, Mapping)
        }
        if len(answers) != len(raw_answers):
            raise ValueError("System One response contains a malformed answer")
        return JevResponse(answers=answers, latency_ms=latency_ms, raw=raw)

    def query(
        self,
        state: JsonValue,
        questions: Mapping[str, Mapping[str, Any]],
        timeout: float = 15,
    ) -> Tuple[Dict[str, Any], int]:
        """Compatibility wrapper that still preserves the complete raw response."""
        response = self.ask(state, questions, timeout)
        return dict(response.raw), response.latency_ms

    def classify_choice_answer(
        self,
        state: JsonValue,
        instruction: JsonValue,
        criteria: Mapping[str, JsonValue],
    ) -> Tuple[JevAnswer, int]:
        response = self.ask(
            state,
            {
                "selection": {
                    "type": "choice",
                    "instructions": instruction,
                    "criteria": criteria,
                }
            },
        )
        return response.answer("selection", "choice"), response.latency_ms

    def classify_choice(
        self,
        state: JsonValue,
        instruction: JsonValue,
        criteria: Mapping[str, JsonValue],
    ) -> Tuple[Optional[str], int]:
        answer, latency_ms = self.classify_choice_answer(state, instruction, criteria)
        return answer.choice, latency_ms

    def evaluate_noul_answer(
        self,
        state: JsonValue,
        instruction: JsonValue,
        criteria: Optional[Mapping[str, JsonValue]] = None,
    ) -> Tuple[JevAnswer, int]:
        question: Dict[str, Any] = {"type": "noul", "instructions": instruction}
        if criteria is not None:
            question["criteria"] = criteria
        response = self.ask(state, {"check": question})
        return response.answer("check", "noul"), response.latency_ms

    def evaluate_noul(
        self, state: JsonValue, instruction: JsonValue
    ) -> Tuple[float, int]:
        answer, latency_ms = self.evaluate_noul_answer(state, instruction)
        return answer.noul or 0.0, latency_ms
