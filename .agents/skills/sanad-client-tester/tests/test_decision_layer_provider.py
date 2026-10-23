"""Provider failures and contradictory replies become escalations, never crashes.

F-01: network, timeout, HTTP error, and malformed bodies all leave ``decide`` as a
typed escalation whose evidence names the error class and the HTTP status, and never
a body or a header.

F-05: a reply whose probabilities disagree with the candidates, or whose choice is
not the argmax, is refused before the guard ever sees it.

Everything here is offline: the transport is a stub opener, and no model is real.
"""

import json
import sys
import unittest
import urllib.error
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from decision_layer.bridge import JevClient, JevClientError  # noqa: E402
from decision_layer.candidates import extract  # noqa: E402
from decision_layer.guard import (  # noqa: E402
    LOW_CONFIDENCE,
    MODEL_CONTRADICTION,
    MODEL_UNAVAILABLE,
)
from decision_layer.layer import DecisionLayer, DecisionRequest  # noqa: E402
from decision_layer.model import (  # noqa: E402
    DEFAULT_DECISION_TIMEOUT,
    DecisionModel,
    JevDecisionModel,
)
from decision_layer.modes import classify  # noqa: E402
from decision_layer.observation import Observation  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "snapshots"
FIXTURE = "08-settings-root.json"
CHOSEN = "nav_tile_profile"


def _observation() -> Observation:
    payload = json.loads((FIXTURES / FIXTURE).read_text(encoding="utf-8"))
    return Observation.from_snapshot(payload, ref=FIXTURE)


def _candidate_ids() -> list:
    observation = _observation()
    evidence = classify(observation.elements)
    table = extract(observation.elements, evidence.mode, evidence.detail)
    return list(table.candidates)


def _request(phase: str = "navigate_settings") -> DecisionRequest:
    return DecisionRequest(goal="Open the Profile settings page", phase=phase)


class _FailingOpener:
    """A stub transport that raises the way a real failure would."""

    def __init__(self, error):
        self._error = error
        self.calls = 0

    def open(self, request, timeout=None):
        self.calls += 1
        raise self._error


class _PayingOpener:
    """A stub transport that answers with a fixed JSON payload."""

    def __init__(self, payload):
        self._payload = payload
        self.calls = 0

    def open(self, request, timeout=None):
        self.calls += 1
        return _Body(json.dumps(self._payload).encode("utf-8"))


class _Body:
    def __init__(self, body):
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self._body


def _decision(payload_or_error, *, timeout=DEFAULT_DECISION_TIMEOUT):
    """Run one real decision step over the real client and a stub transport."""
    import jev_client

    opener = (
        _FailingOpener(payload_or_error)
        if isinstance(payload_or_error, BaseException)
        else _PayingOpener(payload_or_error)
    )
    original = jev_client._OPENER
    jev_client._OPENER = opener
    try:
        client = JevClient(api_key="test-only")
        layer = DecisionLayer(JevDecisionModel(client, timeout=timeout))
        outcome = layer.decide(_observation(), _request())
    finally:
        jev_client._OPENER = original
    return outcome, opener


def _choice_payload(**overrides):
    """A self-consistent answer over the fixture's own candidate table."""
    candidates = _candidate_ids()
    others = [candidate for candidate in candidates if candidate != CHOSEN]
    share = round((1.0 - 0.9) / len(others), 6)
    probabilities = {candidate: share for candidate in others}
    probabilities[CHOSEN] = round(1.0 - share * len(others), 6)
    answer = {
        "choice": CHOSEN,
        "probabilities": probabilities,
        "confidence": 0.9,
    }
    answer.update(overrides)
    return {"answers": {"target": answer}}


def _payload_with(probabilities, choice=CHOSEN, confidence=0.9):
    return {
        "answers": {
            "target": {
                "choice": choice,
                "probabilities": probabilities,
                "confidence": confidence,
            }
        }
    }


class ModelFailureTest(unittest.TestCase):
    """F-01: no provider failure may raise out of ``decide``."""

    def test_a_raising_model_becomes_an_escalation(self):
        class _Broken(DecisionModel):
            name = "broken"

            def choose(self, context):
                raise RuntimeError("the provider process died")

        outcome = DecisionLayer(_Broken()).decide(_observation(), _request())
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, MODEL_UNAVAILABLE)
        self.assertEqual(outcome.escalation.guard["error_class"], "RuntimeError")
        self.assertNotIn("provider process died", json.dumps(outcome.escalation.to_dict()))

    def test_a_malformed_response_becomes_an_escalation(self):
        outcome, opener = _decision({"answers": {"target": {"value": "no typed value"}}})
        self.assertEqual(opener.calls, 1)
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, MODEL_UNAVAILABLE)
        self.assertEqual(outcome.escalation.guard["error_class"], "ValueError")

    def test_a_body_that_is_not_json_becomes_an_escalation(self):
        import jev_client

        class _Garbage:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return b"<html>gateway</html>"

        class _Opener:
            def open(self, request, timeout=None):
                return _Garbage()

        original = jev_client._OPENER
        jev_client._OPENER = _Opener()
        try:
            layer = DecisionLayer(JevDecisionModel(JevClient(api_key="test-only")))
            outcome = layer.decide(_observation(), _request())
        finally:
            jev_client._OPENER = original
        self.assertEqual(outcome.escalation.reason_code, MODEL_UNAVAILABLE)
        self.assertEqual(outcome.escalation.guard["error_code"], "malformed")

    def test_a_timeout_becomes_an_escalation(self):
        outcome, _opener = _decision(TimeoutError("timed out"))
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, MODEL_UNAVAILABLE)
        # The client re-raises it typed, keeping the cause code and no status.
        self.assertEqual(outcome.escalation.guard["error_class"], "JevClientError")
        self.assertEqual(outcome.escalation.guard["error_code"], "timeout")
        self.assertNotIn("status", outcome.escalation.guard)

    def test_a_rate_limit_becomes_an_escalation_with_its_status(self):
        error = urllib.error.HTTPError(
            "https://api.typesafe.ai/v1/systemone", 429, "Too Many Requests", {}, None
        )
        outcome, _opener = _decision(error)
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, MODEL_UNAVAILABLE)
        self.assertEqual(outcome.escalation.guard["status"], 429)
        self.assertEqual(outcome.escalation.guard["error_code"], "http_error")

    def test_a_server_error_becomes_an_escalation_with_its_status(self):
        for status in (500, 503, 529):
            error = urllib.error.HTTPError(
                "https://api.typesafe.ai/v1/systemone", status, "Server Error", {}, None
            )
            outcome, _opener = _decision(error)
            self.assertEqual(outcome.escalation.reason_code, MODEL_UNAVAILABLE, status)
            self.assertEqual(outcome.escalation.guard["status"], status)

    def test_an_unreachable_provider_becomes_an_escalation(self):
        error = urllib.error.URLError(ConnectionRefusedError(61, "Connection refused"))
        outcome, _opener = _decision(error)
        self.assertEqual(outcome.escalation.reason_code, MODEL_UNAVAILABLE)
        self.assertEqual(outcome.escalation.guard["error_code"], "network")

    def test_a_redirect_becomes_an_escalation_and_is_never_followed(self):
        error = urllib.error.HTTPError(
            "https://api.typesafe.ai/v1/systemone", 302, "Found", {"Location": "/x"}, None
        )
        outcome, opener = _decision(error)
        self.assertEqual(opener.calls, 1)
        self.assertEqual(outcome.escalation.guard["status"], 302)
        self.assertEqual(outcome.escalation.guard["error_code"], "redirect")


class ContradictoryReplyEscalationTest(unittest.TestCase):
    """F-05: a self-contradictory reply is escalated, not acted on."""

    def test_probabilities_that_do_not_cover_the_candidates_escalate(self):
        outcome, _opener = _decision(
            _payload_with({CHOSEN: 0.9}, confidence=0.9)
        )
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.escalation.reason_code, MODEL_CONTRADICTION)
        self.assertEqual(
            outcome.escalation.guard["invariant"], "choice_probability_key_set"
        )

    def test_probabilities_that_do_not_sum_to_one_escalate(self):
        candidates = _candidate_ids()
        others = [candidate for candidate in candidates if candidate != CHOSEN]
        share = round(0.5 / len(others), 6)
        probabilities = {candidate: share for candidate in others}
        probabilities[CHOSEN] = 0.4
        outcome, _opener = _decision(_payload_with(probabilities))
        self.assertEqual(outcome.escalation.reason_code, MODEL_CONTRADICTION)
        self.assertEqual(outcome.escalation.guard["invariant"], "choice_probability_sum")

    def test_a_choice_that_is_not_the_argmax_escalates(self):
        candidates = _candidate_ids()
        winner = next(candidate for candidate in candidates if candidate != CHOSEN)
        others = [candidate for candidate in candidates if candidate not in (CHOSEN, winner)]
        share = round(0.1 / len(others), 6)
        probabilities = {candidate: share for candidate in others}
        probabilities[CHOSEN] = 0.2
        probabilities[winner] = round(1.0 - 0.2 - share * len(others), 6)
        outcome, _opener = _decision(_payload_with(probabilities))
        self.assertEqual(outcome.escalation.reason_code, MODEL_CONTRADICTION)
        self.assertEqual(outcome.escalation.guard["invariant"], "choice_is_argmax")

    def test_a_choice_outside_the_candidates_escalates(self):
        outcome, _opener = _decision(
            _payload_with(
                {candidate: round(1.0 / len(_candidate_ids()), 6) for candidate in _candidate_ids()},
                choice="sign_out_btn",
            )
        )
        self.assertEqual(outcome.escalation.reason_code, MODEL_CONTRADICTION)
        self.assertEqual(outcome.escalation.guard["invariant"], "choice_in_criteria")


class ConsistentReplyTest(unittest.TestCase):
    def test_a_consistent_reply_is_admitted(self):
        outcome, _opener = _decision(_choice_payload())
        self.assertTrue(outcome.ok, outcome.escalation and outcome.escalation.to_dict())
        self.assertEqual(outcome.admitted.candidate_id, CHOSEN)

    def test_a_low_confidence_reply_is_refused_by_the_floor(self):
        candidates = _candidate_ids()
        others = [candidate for candidate in candidates if candidate != CHOSEN]
        share = round(0.45 / len(others), 6)
        probabilities = {candidate: share for candidate in others}
        probabilities[CHOSEN] = round(1.0 - share * len(others), 6)
        outcome, _opener = _decision(_payload_with(probabilities, confidence=0.55))
        self.assertEqual(outcome.escalation.reason_code, LOW_CONFIDENCE)


class TypedErrorContractTest(unittest.TestCase):
    def test_the_typed_error_keeps_its_cause_and_status(self):
        error = JevClientError("http_error", "System One returned HTTP 429", status=429)
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(error.code, "http_error")
        self.assertEqual(error.status, 429)

    def test_the_layer_never_exposes_a_provider_body_or_header(self):
        outcome, _opener = _decision(
            urllib.error.HTTPError(
                "https://api.typesafe.ai/v1/systemone",
                500,
                "Server Error",
                {"Authorization": "Bearer secret-value"},
                None,
            )
        )
        payload = json.dumps(outcome.escalation.to_dict())
        self.assertNotIn("secret-value", payload)
        self.assertNotIn("Authorization", payload)
        self.assertNotIn("Server Error", payload)


if __name__ == "__main__":
    unittest.main()
