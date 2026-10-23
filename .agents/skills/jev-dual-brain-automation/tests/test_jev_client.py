import json
import os
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import jev_client  # noqa: E402
from jev_client import JevClient, JevClientError  # noqa: E402


class _Response:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


class _StubOpener:
    """Stands in for the module opener so no test can reach the network."""

    def __init__(self, response):
        self._response = response
        self.calls = []

    def open(self, request, timeout=None):
        self.calls.append((request, timeout))
        return self._response


def _ask(payload, questions=None, **client_kwargs):
    opener = _StubOpener(_Response(payload))
    with patch.object(jev_client, "_OPENER", opener):
        response = JevClient(api_key="test-only", **client_kwargs).ask(
            {"screen": "conversation"},
            questions
            or {
                "target": {
                    "type": "choice",
                    "instructions": "Choose",
                    "criteria": {"send": "Send", "wait": "Wait"},
                }
            },
        )
    return response, opener


class JevClientTest(unittest.TestCase):
    def test_batch_preserves_complete_typed_answers(self):
        payload = {
            "answers": {
                "target": {
                    "choice": "send",
                    "probabilities": {"send": 0.93, "wait": 0.07},
                    "confidence": 0.88,
                }
            }
        }
        response, _opener = _ask(payload)
        choice = response.answer("target", "choice")
        self.assertEqual(choice.choice, "send")
        self.assertEqual(choice.probability_for("send"), 0.93)
        self.assertEqual(choice.confidence, 0.88)

    def test_typed_answers_other_than_choice_need_no_distribution(self):
        payload = {
            "answers": {
                "target": {
                    "choice": "send",
                    "probabilities": {"send": 0.93, "wait": 0.07},
                },
                "severity": {
                    "score": 1.4,
                    "legend": ["low", "medium", "high"],
                    "probabilities": [0.1, 0.4, 0.5],
                    "confidence": 0.72,
                },
                "blocked": {"noul": 0.12},
            }
        }
        response, _opener = _ask(
            payload,
            questions={
                "target": {
                    "type": "choice",
                    "instructions": "Choose",
                    "criteria": {"send": "Send", "wait": "Wait"},
                },
                "severity": {
                    "type": "score",
                    "instructions": "Rate",
                    "criteria": ["low", "medium", "high"],
                },
                "blocked": {"type": "noul", "instructions": "Blocked?"},
            },
        )
        self.assertEqual(response.answer("severity", "score").legend[2], "high")
        self.assertEqual(response.answer("blocked", "noul").noul, 0.12)

    def test_rejects_malformed_answer(self):
        with patch.object(
            jev_client, "_OPENER", _StubOpener(_Response({"answers": {"bad": {"value": "unknown"}}}))
        ):
            with self.assertRaisesRegex(ValueError, "recognized typed value"):
                JevClient(api_key="test-only").ask(
                    "state", {"bad": {"type": "noul", "instructions": "?"}}
                )

    def test_the_default_deadline_is_short(self):
        payload = {
            "answers": {
                "target": {
                    "choice": "send",
                    "probabilities": {"send": 0.9, "wait": 0.1},
                }
            }
        }
        _response, opener = _ask(payload)
        self.assertEqual(opener.calls[0][1], jev_client.DEFAULT_TIMEOUT)
        self.assertEqual(jev_client.DEFAULT_TIMEOUT, 4.0)

    def test_a_caller_may_override_the_deadline(self):
        payload = {
            "answers": {
                "target": {
                    "choice": "send",
                    "probabilities": {"send": 0.9, "wait": 0.1},
                }
            }
        }
        opener = _StubOpener(_Response(payload))
        with patch.object(jev_client, "_OPENER", opener):
            JevClient(api_key="test-only").ask(
                "state",
                {
                    "target": {
                        "type": "choice",
                        "instructions": "Choose",
                        "criteria": {"send": "Send", "wait": "Wait"},
                    }
                },
                timeout=1.25,
            )
        self.assertEqual(opener.calls[0][1], 1.25)


class ContradictoryReplyTest(unittest.TestCase):
    """F-05: a reply that parses but contradicts itself is never usable."""

    def _assert_refused(self, answer_payload, invariant):
        payload = {"answers": {"target": answer_payload}}
        with self.assertRaises(JevClientError) as context:
            _ask(payload)
        error = context.exception
        self.assertEqual(error.code, "contradiction")
        self.assertEqual(error.invariant, invariant)
        # Nothing about the offered criteria or the reply leaks into the message.
        self.assertNotIn("Send", str(error))

    def test_probability_keys_must_match_the_candidates(self):
        self._assert_refused(
            {"choice": "send", "probabilities": {"send": 0.9, "wait": 0.1, "extra": 0.0}},
            "choice_probability_key_set",
        )
        self._assert_refused(
            {"choice": "send", "probabilities": {"send": 1.0}},
            "choice_probability_key_set",
        )

    def test_probabilities_must_sum_to_one(self):
        self._assert_refused(
            {"choice": "send", "probabilities": {"send": 0.5, "wait": 0.2}},
            "choice_probability_sum",
        )

    def test_the_choice_must_be_the_argmax(self):
        self._assert_refused(
            {"choice": "send", "probabilities": {"send": 0.2, "wait": 0.8}},
            "choice_is_argmax",
        )

    def test_a_choice_outside_the_candidates_is_refused(self):
        self._assert_refused(
            {"choice": "delete", "probabilities": {"delete": 1.0, "wait": 0.0}},
            "choice_in_criteria",
        )

    def test_a_probability_outside_the_unit_interval_is_refused(self):
        self._assert_refused(
            {"choice": "send", "probabilities": {"send": 1.4, "wait": -0.4}},
            "choice_probability_range",
        )

    def test_rounding_inside_the_tolerance_is_accepted(self):
        response, _opener = _ask(
            {
                "answers": {
                    "target": {
                        "choice": "send",
                        "probabilities": {"send": 0.67, "wait": 0.34},
                    }
                }
            }
        )
        self.assertEqual(response.answer("target", "choice").choice, "send")


class _StubServer:
    """A throwaway local HTTP server that records every request it receives."""

    def __init__(self, respond):
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler contract
                length = int(self.headers.get("content-length") or 0)
                self.rfile.read(length)
                outer.requests.append(
                    {
                        "path": self.path,
                        "authorization": self.headers.get("authorization"),
                    }
                )
                respond(self)

            def log_message(self, *_args):
                return

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        # A short poll interval keeps shutdown() at milliseconds instead of the
        # default 0.5 s, which would otherwise dominate this test module.
        self._thread = threading.Thread(
            target=self._server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        )
        self.base_url = f"http://127.0.0.1:{self._server.server_port}/v1/systemone"

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *_args):
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)
        return False


class TransportFailureTest(unittest.TestCase):
    """F-01 and F-02: a failure is typed, and a redirect is never followed."""

    def _client(self, base_url: str) -> JevClient:
        client = JevClient(api_key="test-only")
        client.API_URL = base_url
        return client

    def _questions(self):
        return {
            "target": {
                "type": "choice",
                "instructions": "Choose",
                "criteria": {"send": "Send", "wait": "Wait"},
            }
        }

    def test_a_redirect_is_refused_and_never_followed(self):
        def respond(handler):
            if handler.path == "/v1/systemone":
                handler.send_response(302)
                handler.send_header("Location", handler.path + "/elsewhere")
                handler.send_header("Content-Length", "0")
                handler.end_headers()
                return
            handler.send_response(200)
            body = json.dumps(
                {"answers": {"target": {"choice": "send", "probabilities": {"send": 1.0}}}}
            ).encode("utf-8")
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(body)))
            handler.end_headers()
            handler.wfile.write(body)

        with _StubServer(respond) as server:
            with self.assertRaises(JevClientError) as context:
                self._client(server.base_url).ask(
                    {"screen": "conversation"}, self._questions()
                )
            requests = list(server.requests)

        error = context.exception
        self.assertEqual(error.code, "redirect")
        self.assertEqual(error.status, 302)
        # Exactly one request: the redirect target was never contacted, so the
        # bearer token never left the origin it was issued for.
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["path"], "/v1/systemone")
        self.assertEqual(requests[0]["authorization"], "Bearer test-only")
        self.assertNotIn("elsewhere", str(error))

    def test_an_http_error_status_is_preserved(self):
        def respond(handler):
            handler.send_response(429)
            handler.send_header("Content-Length", "0")
            handler.end_headers()

        with _StubServer(respond) as server:
            with self.assertRaises(JevClientError) as context:
                self._client(server.base_url).ask(
                    {"screen": "conversation"}, self._questions()
                )
        self.assertEqual(context.exception.code, "http_error")
        self.assertEqual(context.exception.status, 429)

    def test_a_server_error_status_is_preserved(self):
        def respond(handler):
            handler.send_response(503)
            handler.send_header("Content-Length", "0")
            handler.end_headers()

        with _StubServer(respond) as server:
            with self.assertRaises(JevClientError) as context:
                self._client(server.base_url).ask(
                    {"screen": "conversation"}, self._questions()
                )
        self.assertEqual(context.exception.code, "http_error")
        self.assertEqual(context.exception.status, 503)

    def test_a_deadline_is_reported_as_a_timeout(self):
        def respond(handler):
            time.sleep(0.6)
            handler.send_response(200)
            handler.send_header("Content-Length", "0")
            handler.end_headers()

        with _StubServer(respond) as server:
            with self.assertRaises(JevClientError) as context:
                self._client(server.base_url).ask(
                    {"screen": "conversation"}, self._questions(), timeout=0.1
                )
        self.assertEqual(context.exception.code, "timeout")

    def test_a_body_that_is_not_json_is_malformed(self):
        def respond(handler):
            body = b"<html>not the API</html>"
            handler.send_response(200)
            handler.send_header("Content-Length", str(len(body)))
            handler.end_headers()
            handler.wfile.write(body)

        with _StubServer(respond) as server:
            with self.assertRaises(JevClientError) as context:
                self._client(server.base_url).ask(
                    {"screen": "conversation"}, self._questions()
                )
        self.assertEqual(context.exception.code, "malformed")

    def test_an_unreachable_origin_is_reported_as_a_network_failure(self):
        client = JevClient(api_key="test-only")
        # Port 1 is never listening, so the connection is refused immediately.
        client.API_URL = "http://127.0.0.1:1/v1/systemone"
        with self.assertRaises(JevClientError) as context:
            client.ask({"screen": "conversation"}, self._questions(), timeout=1)
        self.assertEqual(context.exception.code, "network")


class EndpointAndModelOverrideTest(unittest.TestCase):
    """F-06: arguments, then the environment, then today's constants.

    The origin and the model are configuration, never a source edit; the key stays
    out of everything this class can report.
    """

    def _questions(self):
        return {
            "target": {
                "type": "choice",
                "instructions": "Choose",
                "criteria": {"send": "Send", "wait": "Wait"},
            }
        }

    @staticmethod
    def _payload():
        return {
            "answers": {
                "target": {"choice": "send", "probabilities": {"send": 1.0, "wait": 0.0}}
            }
        }

    def _send(self, **client_kwargs):
        """Ask one question over a stub transport and return the request it made."""
        opener = _StubOpener(_Response(self._payload()))
        with patch.object(jev_client, "_OPENER", opener):
            JevClient(api_key="test-only", **client_kwargs).ask(
                {"screen": "conversation"}, self._questions()
            )
        return opener.calls[0][0]

    def test_the_environment_names_the_origin(self):
        with patch.dict(os.environ, {"TYPESAFE_API_URL": "http://127.0.0.1:9/v1/systemone"}):
            client = JevClient(api_key="test-only")
            request = self._send()
        self.assertEqual(request.full_url, "http://127.0.0.1:9/v1/systemone")
        self.assertEqual(client.API_URL, "http://127.0.0.1:9/v1/systemone")

    def test_the_argument_wins_over_the_environment(self):
        with patch.dict(os.environ, {"TYPESAFE_API_URL": "http://127.0.0.1:9/v1/systemone"}):
            request = self._send(api_url="http://127.0.0.1:8/v1/systemone")
        self.assertEqual(request.full_url, "http://127.0.0.1:8/v1/systemone")

    def test_an_unset_environment_leaves_both_defaults_unchanged(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TYPESAFE_API_URL", None)
            os.environ.pop("TYPESAFE_MODEL", None)
            client = JevClient(api_key="test-only")
            request = self._send()
        self.assertEqual(client.API_URL, "https://api.typesafe.ai/v1/systemone")
        self.assertEqual(JevClient.API_URL, "https://api.typesafe.ai/v1/systemone")
        self.assertEqual(client.model, "jev-latest")
        self.assertEqual(json.loads(request.data.decode("utf-8"))["model"], "jev-latest")

    def test_the_environment_names_the_model(self):
        with patch.dict(os.environ, {"TYPESAFE_MODEL": "jev-1.14.0"}):
            request = self._send()
        self.assertEqual(json.loads(request.data.decode("utf-8"))["model"], "jev-1.14.0")

    def test_the_model_argument_wins_over_the_environment(self):
        with patch.dict(os.environ, {"TYPESAFE_MODEL": "jev-1.14.0"}):
            request = self._send(model="jev-2")
        self.assertEqual(json.loads(request.data.decode("utf-8"))["model"], "jev-2")

    def test_the_test_seam_still_wins_after_construction(self):
        with patch.dict(os.environ, {"TYPESAFE_API_URL": "http://127.0.0.1:9/v1/systemone"}):
            client = JevClient(api_key="test-only")
        client.API_URL = "http://127.0.0.1:8/v1/systemone"
        opener = _StubOpener(_Response(self._payload()))
        with patch.object(jev_client, "_OPENER", opener):
            client.ask({"screen": "conversation"}, self._questions())
        self.assertEqual(opener.calls[0][0].full_url, "http://127.0.0.1:8/v1/systemone")

    def test_an_overridden_origin_still_refuses_a_redirect(self):
        def respond(handler):
            handler.send_response(302)
            handler.send_header("Location", "/elsewhere")
            handler.send_header("Content-Length", "0")
            handler.end_headers()

        with _StubServer(respond) as server:
            with patch.dict(os.environ, {"TYPESAFE_API_URL": server.base_url}):
                with self.assertRaises(JevClientError) as context:
                    JevClient(api_key="test-only").ask(
                        {"screen": "conversation"}, self._questions()
                    )
            requests = list(server.requests)

        self.assertEqual(context.exception.code, "redirect")
        self.assertEqual(context.exception.status, 302)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["path"], "/v1/systemone")

    def test_the_key_never_appears_in_a_repr_or_an_error(self):
        client = JevClient(api_key="secret-value", api_url="http://127.0.0.1:1/v1/systemone")
        self.assertNotIn("secret-value", repr(client))
        self.assertNotIn("secret-value", str(client))
        with self.assertRaises(JevClientError) as context:
            client.ask({"screen": "conversation"}, self._questions(), timeout=1)
        self.assertNotIn("secret-value", str(context.exception))
        self.assertNotIn("secret-value", repr(context.exception))



if __name__ == "__main__":
    unittest.main()