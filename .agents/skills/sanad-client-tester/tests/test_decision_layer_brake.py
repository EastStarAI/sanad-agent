"""F-10: one brake owns the requests-per-minute window and the per-run USD ceiling.

The brake is the single owner of both limits, so these tests hold it to four
properties: it refuses instead of waiting, it refuses *before* the model is called,
it charges the same shared price everywhere, and a reply with no usage is charged a
conservative estimate instead of nothing.

Everything here is offline: the models are fakes and the clock is injected.
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.brake import (  # noqa: E402
    ESTIMATED_INPUT_TOKENS_PER_CALL,
    USD_PER_MILLION_INPUT_TOKENS,
    BudgetBrake,
)
from decision_layer.guard import (  # noqa: E402
    COST_CEILING_REACHED,
    RATE_LIMITED,
    REASON_CODES,
)
from decision_layer.layer import DecisionLayer, DecisionRequest  # noqa: E402
from decision_layer.model import DecisionModel, ModelChoice  # noqa: E402
from decision_layer.observation import Observation  # noqa: E402
from decision_layer.trace import TraceWriter, load_trace  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "snapshots"
FIXTURE = "08-settings-root.json"
CHOSEN = "nav_tile_profile"
# One call charged at the estimate, for the ceiling arithmetic below.
ESTIMATED_CALL_USD = ESTIMATED_INPUT_TOKENS_PER_CALL * USD_PER_MILLION_INPUT_TOKENS / 1_000_000


def _observation() -> Observation:
    payload = json.loads((FIXTURES / FIXTURE).read_text(encoding="utf-8"))
    return Observation.from_snapshot(payload, ref=FIXTURE)


def _request(phase: str = "navigate_settings") -> DecisionRequest:
    return DecisionRequest(goal="Open the Profile settings page", phase=phase)


class _Clock:
    """An injected clock: the window slides only when a test says so."""

    def __init__(self) -> None:
        self.now = 1_000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class _CountingModel(DecisionModel):
    """A model that records every call, so a refusal can prove it never happened."""

    name = "counting"

    def __init__(self, input_tokens=None) -> None:
        self.calls = []
        self._input_tokens = input_tokens

    def choose(self, context) -> ModelChoice:
        self.calls.append(context.phase)
        metadata = {} if self._input_tokens is None else {"input_tokens": self._input_tokens}
        return ModelChoice(
            choice=CHOSEN,
            confidence=0.9,
            probabilities={CHOSEN: 0.9, "abstain": 0.1},
            latency_ms=1,
            model="counting-1",
            metadata=metadata,
        )


class SharedPriceTest(unittest.TestCase):
    def test_the_price_is_defined_in_exactly_one_module(self):
        package = SCRIPTS / "decision_layer"
        definers = [
            path.name
            for path in sorted(package.glob("*.py"))
            if "USD_PER_MILLION_INPUT_TOKENS =" in path.read_text(encoding="utf-8")
        ]
        self.assertEqual(definers, ["brake.py"])

    def test_the_smoke_report_charges_the_shared_price(self):
        from decision_layer import smoke

        self.assertEqual(
            smoke.USD_PER_MILLION_INPUT_TOKENS, USD_PER_MILLION_INPUT_TOKENS
        )

    def test_a_million_input_tokens_cost_the_documented_price(self):
        charge = BudgetBrake().charge(1_000_000)
        self.assertAlmostEqual(charge.usd, 0.042)
        self.assertEqual(charge.input_tokens, 1_000_000)
        self.assertFalse(charge.estimated)


class EstimatedUsageTest(unittest.TestCase):
    def test_a_reply_without_usage_is_charged_the_conservative_estimate(self):
        brake = BudgetBrake()
        charge = brake.charge(None)
        self.assertTrue(charge.estimated)
        self.assertEqual(charge.input_tokens, ESTIMATED_INPUT_TOKENS_PER_CALL)
        self.assertAlmostEqual(charge.usd, ESTIMATED_CALL_USD)
        self.assertAlmostEqual(brake.spend_usd, ESTIMATED_CALL_USD)
        self.assertEqual(brake.input_tokens, ESTIMATED_INPUT_TOKENS_PER_CALL)

    def test_a_reported_usage_replaces_the_estimate(self):
        brake = BudgetBrake()
        charge = brake.charge(1_500)
        self.assertFalse(charge.estimated)
        self.assertEqual(charge.input_tokens, 1_500)
        self.assertAlmostEqual(
            charge.usd, 1_500 * USD_PER_MILLION_INPUT_TOKENS / 1_000_000
        )

    def test_a_nonsense_usage_is_charged_the_estimate(self):
        brake = BudgetBrake()
        for value in (True, -5, "1200", 1.5, None):
            self.assertTrue(brake.charge(value).estimated, value)


class RateLimitTest(unittest.TestCase):
    def test_the_limit_refuses_instead_of_waiting(self):
        clock = _Clock()
        brake = BudgetBrake(requests_per_minute=2, clock=clock)
        self.assertIsNone(brake.admit())
        self.assertIsNone(brake.admit())
        refusal = brake.admit()
        self.assertIsNotNone(refusal)
        self.assertEqual(refusal.code, RATE_LIMITED)
        self.assertEqual(refusal.evidence["requests_per_minute"], 2)
        self.assertEqual(refusal.evidence["observed"], 2)
        self.assertIn("spend_usd", refusal.evidence)
        self.assertIn("remaining_usd", refusal.evidence)

    def test_a_refused_request_is_not_counted(self):
        clock = _Clock()
        brake = BudgetBrake(requests_per_minute=1, clock=clock)
        self.assertIsNone(brake.admit())
        self.assertEqual(brake.admit().code, RATE_LIMITED)
        self.assertEqual(brake.requests_in_window(), 1)

    def test_the_window_slides_after_a_minute(self):
        clock = _Clock()
        brake = BudgetBrake(requests_per_minute=1, clock=clock)
        self.assertIsNone(brake.admit())
        self.assertEqual(brake.admit().code, RATE_LIMITED)
        clock.advance(61)
        self.assertIsNone(brake.admit())
        self.assertEqual(brake.requests_in_window(), 1)


class CostCeilingTest(unittest.TestCase):
    def test_the_ceiling_refuses_the_call_that_would_cross_it(self):
        brake = BudgetBrake(max_usd=ESTIMATED_CALL_USD + 0.000_016)
        self.assertIsNone(brake.admit())
        brake.charge(None)
        refusal = brake.admit()
        self.assertIsNotNone(refusal)
        self.assertEqual(refusal.code, COST_CEILING_REACHED)
        self.assertAlmostEqual(refusal.evidence["max_usd"], ESTIMATED_CALL_USD + 0.000_016)
        self.assertAlmostEqual(refusal.evidence["spend_usd"], ESTIMATED_CALL_USD)
        self.assertAlmostEqual(
            refusal.evidence["remaining_usd"], 0.000_016, places=8
        )
        self.assertAlmostEqual(refusal.evidence["next_call_usd"], ESTIMATED_CALL_USD)

    def test_an_unconfigured_brake_never_refuses(self):
        brake = BudgetBrake()
        for _ in range(50):
            self.assertIsNone(brake.admit())
        self.assertIsNone(brake.remaining_usd)
        self.assertEqual(brake.to_dict()["max_usd"], None)

    def test_impossible_limits_fail_closed(self):
        with self.assertRaises(ValueError):
            BudgetBrake(requests_per_minute=0)
        with self.assertRaises(ValueError):
            BudgetBrake(max_usd=-1)


class LayerBrakeTest(unittest.TestCase):
    """Both trips are escalations, and neither reaches the model."""

    def test_the_rate_limit_refuses_before_the_model_call(self):
        model = _CountingModel()
        layer = DecisionLayer(model, brake=BudgetBrake(requests_per_minute=1))
        first = layer.decide(_observation(), _request())
        self.assertTrue(first.ok)
        second = layer.decide(_observation(), _request())
        self.assertFalse(second.ok)
        self.assertEqual(second.escalation.reason_code, RATE_LIMITED)
        self.assertEqual(len(model.calls), 1)
        self.assertEqual(second.escalation.guard["requests_per_minute"], 1)

    def test_a_spent_ceiling_refuses_before_the_model_call(self):
        model = _CountingModel(input_tokens=None)
        layer = DecisionLayer(
            model, brake=BudgetBrake(max_usd=ESTIMATED_CALL_USD + 0.000_016)
        )
        self.assertTrue(layer.decide(_observation(), _request()).ok)
        second = layer.decide(_observation(), _request())
        self.assertFalse(second.ok)
        self.assertEqual(second.escalation.reason_code, COST_CEILING_REACHED)
        self.assertEqual(len(model.calls), 1)
        self.assertAlmostEqual(second.escalation.guard["spend_usd"], ESTIMATED_CALL_USD)
        self.assertAlmostEqual(second.escalation.guard["remaining_usd"], 0.000_016, places=8)

    def test_a_zero_ceiling_refuses_the_very_first_decision(self):
        model = _CountingModel()
        layer = DecisionLayer(model, brake=BudgetBrake(max_usd=0.0))
        outcome = layer.decide(_observation(), _request())
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, COST_CEILING_REACHED)
        self.assertEqual(outcome.escalation.guard["remaining_usd"], 0.0)
        self.assertEqual(model.calls, [])

    def test_a_reported_usage_is_what_the_ceiling_charges(self):
        model = _CountingModel(input_tokens=3_000)
        layer = DecisionLayer(model, brake=BudgetBrake(max_usd=1.0))
        layer.decide(_observation(), _request())
        self.assertAlmostEqual(
            layer.brake.spend_usd, 3_000 * USD_PER_MILLION_INPUT_TOKENS / 1_000_000
        )


class TraceSpendTest(unittest.TestCase):
    def test_the_trace_records_the_running_spend(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.jsonl"
            layer = DecisionLayer(
                _CountingModel(input_tokens=1_501),
                trace=TraceWriter(path),
                brake=BudgetBrake(max_usd=1.0),
            )
            layer.decide(_observation(), _request("open_settings"))
            layer.decide(_observation(), _request("open_settings"))
            records = load_trace(path)
        self.assertEqual(len(records), 2)
        self.assertAlmostEqual(
            records[1]["spend_usd"], 2 * 1_501 * USD_PER_MILLION_INPUT_TOKENS / 1_000_000
        )
        self.assertGreater(records[1]["spend_usd"], records[0]["spend_usd"])


class DocumentedCodesTest(unittest.TestCase):
    def test_both_brake_codes_are_part_of_the_reason_code_contract(self):
        self.assertIn(RATE_LIMITED, REASON_CODES)
        self.assertIn(COST_CEILING_REACHED, REASON_CODES)


if __name__ == "__main__":
    unittest.main()
