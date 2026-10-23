"""Minimal typed client for the TypeSafe System One HTTP API.

Four properties are load-bearing for a live decision loop, and each one is
checked here rather than at a caller:

* **no redirects** - a 3xx would carry the bearer token to another origin, so a
  redirect is an error and never a hop (``_NoRedirect``);
* **a typed failure** - a network, timeout, or HTTP failure raises
  ``JevClientError`` with its cause code and the HTTP status, never a generic
  ``RuntimeError``, and never a response body or a header;
* **a short deadline** - one decision is worth a few hundred milliseconds, so the
  default is ``DEFAULT_TIMEOUT`` seconds and every entry point accepts another;
* **a self-consistent answer** - choice probabilities must cover exactly the
  offered candidates, sum to one, and rank the chosen option first; a reply that
  contradicts itself is refused instead of being acted on.
"""

from __future__ import annotations

import http.client
import json
import math
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple, Union

JsonValue = Union[str, int, float, bool, None, Dict[str, Any], list[Any]]

# One fast decision, not a batch job: a hung call blocks an interactive step.
DEFAULT_TIMEOUT = 4.0
# Jev prints probabilities to two decimals; this band absorbs that rounding and
# still refuses an answer whose mass is genuinely elsewhere.
PROBABILITY_SUM_TOLERANCE = 0.01 + 1e-12
ARGMAX_TOLERANCE = 1e-9


class JevClientError(RuntimeError):
    """A request that produced no usable answer, typed by cause.

    ``code`` is one of ``network``, ``timeout``, ``http_error``, ``redirect``,
    ``malformed``, or ``contradiction``; ``status`` is the HTTP status when a
    response existed at all; ``invariant`` names the consistency rule a
    contradictory reply broke. The message is built here, so it never carries a
    provider body or a header and is safe to escalate.
    """

    def __init__(
        self,
        code: str,
        detail: str = "",
        status: Optional[int] = None,
        invariant: Optional[str] = None,
    ) -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail
        self.status = status
        self.invariant = invariant


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect: this client has exactly one origin.

    ``redirect_request`` returning ``None`` makes urllib raise ``HTTPError`` for
    the 3xx instead of replaying the request - and its ``Authorization`` header -
    against the redirect target.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


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
        timeout: float = DEFAULT_TIMEOUT,
    ) -> JevResponse:
        """Evaluate independent typed questions against one structured state.

        Raises ``JevClientError`` for anything that means "do not use this result":
        an unreachable origin, a deadline, a redirect, an HTTP error status, a body
        that is not the documented shape, or an answer that contradicts itself.
        """
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
        raw = self._post(request, timeout)
        latency_ms = round((time.monotonic() - started) * 1000)

        raw_answers = raw.get("answers")
        if not isinstance(raw_answers, Mapping):
            raise JevClientError(
                "malformed", "System One response has no answers object"
            )
        answers = {
            str(question_id): JevAnswer.from_payload(answer)
            for question_id, answer in raw_answers.items()
            if isinstance(answer, Mapping)
        }
        if len(answers) != len(raw_answers):
            raise JevClientError(
                "malformed", "System One response contains a malformed answer"
            )
        self._validate_answers(questions, answers)
        return JevResponse(answers=answers, latency_ms=latency_ms, raw=raw)

    # -- transport --------------------------------------------------------
    def _post(self, request: urllib.request.Request, timeout: float) -> Dict[str, Any]:
        """One POST with no redirect and no retry; failures stay typed."""
        try:
            with _OPENER.open(request, timeout=timeout) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            status = int(error.code)
            code = "redirect" if 300 <= status < 400 else "http_error"
            raise JevClientError(
                code, f"System One returned HTTP {status}", status=status
            ) from None
        except TimeoutError:
            raise JevClientError(
                "timeout", "System One did not answer before the deadline"
            ) from None
        except urllib.error.URLError as error:
            timed_out = isinstance(getattr(error, "reason", None), TimeoutError)
            raise JevClientError(
                "timeout" if timed_out else "network",
                "System One did not answer before the deadline"
                if timed_out
                else "System One could not be reached",
            ) from None
        except (http.client.HTTPException, OSError):
            raise JevClientError(
                "network", "the System One connection failed"
            ) from None
        try:
            raw = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise JevClientError(
                "malformed", "System One returned a body that is not JSON"
            ) from None
        if not isinstance(raw, Mapping):
            raise JevClientError(
                "malformed", "System One returned a body that is not an object"
            )
        return dict(raw)

    # -- answer integrity -------------------------------------------------
    def _validate_answers(
        self,
        questions: Mapping[str, Mapping[str, Any]],
        answers: Mapping[str, JevAnswer],
    ) -> None:
        """Refuse a reply that contradicts the question that produced it."""
        for name, question in questions.items():
            answer = answers.get(str(name))
            if answer is None or answer.kind != "choice":
                continue
            criteria = question.get("criteria")
            if not isinstance(criteria, Mapping) or not criteria:
                continue
            self._validate_choice(str(name), answer, tuple(str(key) for key in criteria))

    @staticmethod
    def _validate_choice(
        name: str, answer: JevAnswer, options: Sequence[str]
    ) -> None:
        chosen = answer.choice
        if chosen is None or chosen not in options:
            raise JevClientError(
                "contradiction",
                f"{name}: the answer chose an option that was not offered",
                invariant="choice_in_criteria",
            )
        probabilities = answer.probabilities
        if not isinstance(probabilities, Mapping):
            raise JevClientError(
                "contradiction",
                f"{name}: the answer carries no probability distribution",
                invariant="choice_probability_key_set",
            )
        found = {str(key) for key in probabilities}
        expected = set(options)
        if found != expected:
            missing = sorted(expected - found)
            extra = sorted(found - expected)
            raise JevClientError(
                "contradiction",
                f"{name}: probabilities do not cover the candidates "
                f"(missing {missing or 'none'}, unexpected {extra or 'none'})",
                invariant="choice_probability_key_set",
            )
        values: Dict[str, float] = {}
        for option in options:
            value = probabilities[option]
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise JevClientError(
                    "contradiction",
                    f"{name}: probability for {option} is not numeric",
                    invariant="choice_probability_value",
                )
            number = float(value)
            if not math.isfinite(number) or not -1e-6 <= number <= 1 + 1e-6:
                raise JevClientError(
                    "contradiction",
                    f"{name}: probability for {option} is outside 0..1",
                    invariant="choice_probability_range",
                )
            values[option] = number
        total = sum(values.values())
        if abs(total - 1.0) > PROBABILITY_SUM_TOLERANCE:
            raise JevClientError(
                "contradiction",
                f"{name}: probabilities sum to {round(total, 4)}",
                invariant="choice_probability_sum",
            )
        top = max(values.values())
        if values[chosen] < top - ARGMAX_TOLERANCE:
            raise JevClientError(
                "contradiction",
                f"{name}: the chosen option is not the most probable",
                invariant="choice_is_argmax",
            )

    def query(
        self,
        state: JsonValue,
        questions: Mapping[str, Mapping[str, Any]],
        timeout: float = DEFAULT_TIMEOUT,
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
