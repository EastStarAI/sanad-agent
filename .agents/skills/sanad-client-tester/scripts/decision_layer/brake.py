"""One owner for the requests-per-minute window and the per-run USD ceiling.

A live decision loop spends real quota and real money, so both limits live in one
card-checked object instead of being spread across callers:

* the **requests-per-minute window** counts the calls this brake admitted in the
  trailing minute and refuses one more instead of sleeping or retrying;
* the **per-run USD ceiling** charges every reply at one documented price and
  refuses a call that would cross the ceiling *before* it is made.

Both refusals are ``guard.Refusal`` values carrying ``rate_limited`` or
``cost_ceiling_reached``, so ``DecisionLayer.decide`` turns them into the same
bounded escalation every other refusal already uses. The brake never raises, never
sleeps, never calls a model, and never reads a key.

Spend comes from the reply's own ``usage.input_tokens`` (exposed as
``ModelChoice.input_tokens``). A reply that omits usage is charged the documented
conservative estimate below and marked estimated, so a missing field cannot buy
extra budget.
"""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass
from typing import Any, Callable, Deque, Dict, Optional

from .guard import COST_CEILING_REACHED, RATE_LIMITED, Refusal

# The one price this package charges: TypeSafe's documented list price per million
# input tokens. ``smoke`` imports this value instead of keeping its own copy.
USD_PER_MILLION_INPUT_TOKENS = 0.042
# A reply that reports no usage is charged this many input tokens. It sits above the
# 1,735-token payload p95 measured on this surface, so an omitted field cannot buy
# budget, and the charge is marked estimated wherever it is reported.
ESTIMATED_INPUT_TOKENS_PER_CALL = 2_000
# Trailing window for the requests-per-minute limit: one sliding minute.
WINDOW_SECONDS = 60.0


@dataclass(frozen=True)
class BrakeCharge:
    """What one admitted call cost, and whether the amount was estimated."""

    input_tokens: int
    usd: float
    estimated: bool

    def to_dict(self) -> dict:
        return {
            "input_tokens": self.input_tokens,
            "usd": round(self.usd, 8),
            "estimated": self.estimated,
        }


class BudgetBrake:
    """Refuses a call that would cross either limit; it never waits for capacity."""

    def __init__(
        self,
        *,
        requests_per_minute: Optional[int] = None,
        max_usd: Optional[float] = None,
        price_usd_per_million_input_tokens: float = USD_PER_MILLION_INPUT_TOKENS,
        estimated_input_tokens: int = ESTIMATED_INPUT_TOKENS_PER_CALL,
        window_seconds: float = WINDOW_SECONDS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if requests_per_minute is not None and requests_per_minute < 1:
            raise ValueError("requests_per_minute must be at least 1 when set")
        if max_usd is not None and max_usd < 0:
            raise ValueError("max_usd must not be negative when set")
        if estimated_input_tokens < 1:
            raise ValueError("estimated_input_tokens must be at least 1")
        self.requests_per_minute = requests_per_minute
        self.max_usd = max_usd
        self.price_usd_per_million_input_tokens = price_usd_per_million_input_tokens
        self.estimated_input_tokens = estimated_input_tokens
        self.window_seconds = window_seconds
        self._clock = clock
        self._window: Deque[float] = deque()
        self._spend_usd = 0.0
        self._input_tokens = 0
        self._estimated_calls = 0

    # -- read -------------------------------------------------------------
    @property
    def spend_usd(self) -> float:
        return self._spend_usd

    @property
    def remaining_usd(self) -> Optional[float]:
        """Budget left, or ``None`` when no ceiling was configured."""
        if self.max_usd is None:
            return None
        return max(0.0, self.max_usd - self._spend_usd)

    @property
    def input_tokens(self) -> int:
        return self._input_tokens

    def requests_in_window(self) -> int:
        self._prune()
        return len(self._window)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "requests_per_minute": self.requests_per_minute,
            "requests_in_window": self.requests_in_window(),
            "window_seconds": self.window_seconds,
            "max_usd": self.max_usd,
            "spend_usd": round(self._spend_usd, 8),
            "remaining_usd": (
                None if self.remaining_usd is None else round(self.remaining_usd, 8)
            ),
            "input_tokens": self._input_tokens,
            "estimated_calls": self._estimated_calls,
        }

    # -- write ------------------------------------------------------------
    def admit(self) -> Optional[Refusal]:
        """Refuse one more request when either limit would be crossed.

        An admitted request is counted in the window immediately, so a call that
        fails at the provider still spent quota. A refused request is not counted.
        """
        self._prune()
        if (
            self.requests_per_minute is not None
            and len(self._window) >= self.requests_per_minute
        ):
            return Refusal(
                RATE_LIMITED,
                f"the {self.requests_per_minute}/minute limit is already spent",
                {
                    "requests_per_minute": self.requests_per_minute,
                    "observed": len(self._window),
                    "window_seconds": self.window_seconds,
                    "spend_usd": round(self._spend_usd, 8),
                    "remaining_usd": self.remaining_usd,
                },
            )
        next_call_usd = self._usd_for(self.estimated_input_tokens)
        if self.max_usd is not None and self._spend_usd + next_call_usd > self.max_usd:
            return Refusal(
                COST_CEILING_REACHED,
                "the next decision would cross the per-run USD ceiling",
                {
                    "max_usd": self.max_usd,
                    "spend_usd": round(self._spend_usd, 8),
                    "remaining_usd": self.remaining_usd,
                    "next_call_usd": round(next_call_usd, 8),
                    "estimated_input_tokens": self.estimated_input_tokens,
                },
            )
        self._window.append(self._clock())
        return None

    def charge(self, input_tokens: Optional[int] = None) -> BrakeCharge:
        """Charge one admitted call, estimating when the reply reported no usage."""
        reported = (
            input_tokens
            if isinstance(input_tokens, int)
            and not isinstance(input_tokens, bool)
            and input_tokens >= 0
            else None
        )
        estimated = reported is None
        charged = self.estimated_input_tokens if estimated else reported
        usd = self._usd_for(charged)
        self._spend_usd += usd
        self._input_tokens += charged
        if estimated:
            self._estimated_calls += 1
        return BrakeCharge(input_tokens=charged, usd=usd, estimated=estimated)

    # -- internals --------------------------------------------------------
    def _usd_for(self, input_tokens: int) -> float:
        return input_tokens * self.price_usd_per_million_input_tokens / 1_000_000

    def _prune(self) -> None:
        edge = self._clock() - self.window_seconds
        while self._window and self._window[0] <= edge:
            self._window.popleft()
