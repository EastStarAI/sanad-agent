"""Provider-agnostic decision model interface.

The layer asks one question per step - "which of these closed candidates is the
next action?" - and every implementation answers with the same small value
object. ``ModelChoice`` deliberately exposes the minimal shape the Jev workflow
engine's ``admit_choice`` consumes (``kind``, ``choice``, ``confidence``,
``probability_for``), so the *same* tested confidence gate applies to every
provider and swapping models cannot touch the guard, the extractor, or the mode
classifier.

Two implementations ship here:

* ``FakeDecisionModel`` / ``ScriptedDecisionModel`` - deterministic, offline, and
  the only models the test suite uses;
* ``JevDecisionModel`` - one implementation over the typed TypeSafe client. It is
  the only place in this package that knows what Jev is.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Dict, Mapping, Optional, Tuple

# One decision is a step in an interactive loop, not a batch job: P0 measured p50
# 342 ms and p95 957 ms, so a four-second deadline is already three times the
# slowest observed call and still short enough to hand the step back to the agent.
# Override it per model (``JevDecisionModel(timeout=...)``) or from the CLI
# (``decide --timeout``).
DEFAULT_DECISION_TIMEOUT = 4.0


@dataclass(frozen=True)
class DecisionContext:
    """Everything one decision is allowed to see. Named fields, no prose blob."""

    goal: str
    phase: str
    mode: str
    mode_detail: Optional[str]
    candidates: Mapping[str, str]
    instructions: Optional[str] = None
    completed_phases: Tuple[str, ...] = ()
    recent_actions: Tuple[Mapping[str, Any], ...] = ()

    def state(self) -> Dict[str, Any]:
        """Structured state for a provider call.

        Candidates are *not* repeated here: ``question()["criteria"]`` is their only
        carrier, so one decision payload describes each option exactly once.
        """
        return {
            "goal": self.goal,
            "phase": self.phase,
            "surface": "sanad desktop client",
            "screen_mode": self.mode,
            "screen_detail": self.mode_detail,
            "completed_phases": list(self.completed_phases),
            "recent_actions": [dict(action) for action in self.recent_actions],
        }

    def question(self) -> Dict[str, Any]:
        return {
            "type": "choice",
            "instructions": self.instructions or self.goal,
            "criteria": dict(self.candidates),
        }

    def candidate_ids(self) -> Tuple[str, ...]:
        return tuple(self.candidates)


@dataclass(frozen=True)
class ModelChoice:
    """One provider-neutral judgment.

    ``kind``/``choice``/``confidence``/``probability_for`` exist so this object
    satisfies the reusable ``admit_choice`` admission gate unchanged.
    """

    choice: Optional[str]
    confidence: Optional[float] = None
    probabilities: Optional[Mapping[str, float]] = None
    latency_ms: Optional[int] = None
    model: str = "unknown"
    kind: str = "choice"
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def probability_for(self, option: str) -> Optional[float]:
        if not isinstance(self.probabilities, Mapping):
            return None
        value = self.probabilities.get(option)
        return float(value) if value is not None else None

    def to_dict(self) -> dict:
        return {
            "choice": self.choice,
            "confidence": self.confidence,
            "probability": self.probability_for(self.choice) if self.choice else None,
            "latency_ms": self.latency_ms,
            "model": self.model,
        }


class DecisionModel(ABC):
    """The whole provider contract: answer one closed-choice question."""

    name = "decision-model"

    @abstractmethod
    def choose(self, context: DecisionContext) -> ModelChoice:
        """Return exactly one candidate id, ``abstain``, or ``reobserve``."""


class FakeDecisionModel(DecisionModel):
    """Deterministic single-answer model for tests and dry runs."""

    def __init__(
        self,
        choice: str,
        confidence: float = 1.0,
        *,
        name: str = "fake",
        model: str = "fake-1",
        latency_ms: int = 1,
        probabilities: Optional[Mapping[str, float]] = None,
    ) -> None:
        self._choice = choice
        self._confidence = confidence
        self._probabilities = probabilities
        self.name = name
        self._model = model
        self._latency_ms = latency_ms
        self.calls: list = []

    def choose(self, context: DecisionContext) -> ModelChoice:
        self.calls.append(context.phase)
        probabilities = dict(self._probabilities or {})
        if not probabilities:
            probabilities = {self._choice: self._confidence}
        return ModelChoice(
            choice=self._choice,
            confidence=self._confidence,
            probabilities=probabilities,
            latency_ms=self._latency_ms,
            model=self._model,
            metadata={"scripted": True},
        )


class ScriptedDecisionModel(DecisionModel):
    """One scripted answer per phase, for multi-step tests."""

    def __init__(
        self,
        script: Mapping[str, Tuple[str, float]],
        *,
        name: str = "scripted",
        model: str = "scripted-1",
        latency_ms: int = 1,
    ) -> None:
        self._script = dict(script)
        self.name = name
        self._model = model
        self._latency_ms = latency_ms
        self.asked: list = []

    def choose(self, context: DecisionContext) -> ModelChoice:
        self.asked.append(context.phase)
        choice, confidence = self._script.get(
            context.phase, ("reobserve", 1.0)
        )
        return ModelChoice(
            choice=choice,
            confidence=confidence,
            probabilities={choice: confidence},
            latency_ms=self._latency_ms,
            model=self._model,
            metadata={"scripted": True},
        )


class JevDecisionModel(DecisionModel):
    """TypeSafe System One implementation; the only Jev-aware code in this layer."""

    name = "jev"

    def __init__(
        self,
        client: Any,
        *,
        model: Optional[str] = None,
        timeout: float = DEFAULT_DECISION_TIMEOUT,
    ) -> None:
        self._client = client
        self._model = model or getattr(client, "model", "jev-latest")
        self._timeout = timeout

    @classmethod
    def from_environment(cls, **kwargs: Any) -> "JevDecisionModel":
        from .bridge import JevClient

        accepted = {key: kwargs[key] for key in ("model",) if key in kwargs}
        return cls(
            JevClient(**accepted),
            timeout=kwargs.get("timeout", DEFAULT_DECISION_TIMEOUT),
        )

    def choose(self, context: DecisionContext) -> ModelChoice:
        # No try/except here on purpose: ``DecisionLayer.decide`` is the single place
        # that turns a provider failure into an escalation, so every provider gets
        # the same behaviour and this method keeps one job.
        response = self._client.ask(
            context.state(),
            {"target": context.question()},
            timeout=self._timeout,
        )
        answer = response.answer("target", "choice")
        raw = dict(response.raw or {})
        usage = raw.get("usage") if isinstance(raw.get("usage"), Mapping) else {}
        probabilities = (
            answer.probabilities if isinstance(answer.probabilities, Mapping) else None
        )
        return ModelChoice(
            choice=answer.choice,
            confidence=answer.confidence,
            probabilities=probabilities,
            latency_ms=response.latency_ms,
            model=str(raw.get("model") or self._model),
            metadata={
                "input_tokens": usage.get("input_tokens"),
                "output_tokens": usage.get("output_tokens"),
                "answer_kind": answer.kind,
                "asked": context.phase,
                "instructions": context.instructions or context.goal,
            },
        )


def build_model(spec: str, *, timeout: float = DEFAULT_DECISION_TIMEOUT) -> DecisionModel:
    """Build a model from a compact CLI spec.

    ``fake:<id>:<confidence>`` and ``scripted:<phase>=<id>@<conf>,...`` need no
    network; ``jev`` loads the TypeSafe key exactly as the Jev skill does.
    """
    if spec.startswith("fake:"):
        _, choice, confidence = (spec.split(":", 2) + ["1.0"])[:3]
        return FakeDecisionModel(choice, float(confidence))
    if spec.startswith("scripted:"):
        script: Dict[str, Tuple[str, float]] = {}
        for item in spec[len("scripted:") :].split(","):
            if not item:
                continue
            phase, _, rest = item.partition("=")
            choice, _, confidence = rest.partition("@")
            script[phase] = (choice, float(confidence or 1.0))
        return ScriptedDecisionModel(script)
    if spec == "jev":
        return JevDecisionModel.from_environment(timeout=timeout)
    raise ValueError(f"unknown model spec {spec!r}")
