---
title: "Provider Account Usage Limits QA Matrix"
description: "Regression coverage for provider-instance usage parsing, protocol isolation, freshness, stale responses, and card presentation."
---

# Provider Account Usage Limits QA Matrix

## Safety and identity

| Scenario | Expected result |
|---|---|
| Fetch usage for account A while account B is also configured | The daemon resolves only A's credential and the snapshot is keyed to A's provider instance id. |
| Switch Settings from device A to device B while A has a pending request | B renders from its own state; A's late support or usage result is ignored. |
| Delete an instance while usage is pending | The late result cannot recreate the removed entry or disclosure. |
| Dispose the provider flow while requests are pending | No closed-state emission, exception, or later UI mutation occurs. |
| Provider returns extra fields or a malformed optional field | Known valid windows remain usable; raw payload and credentials never enter UI or logs. |
| Usage endpoint fails | Provider readiness and model execution remain unchanged. |

## Parsing and protocol

| Scenario | Expected result |
|---|---|
| ChatGPT returns Weekly and Monthly without Session | Exactly Weekly and Monthly cross the protocol; no Session placeholder is synthesized. |
| Only used percentage is present | Remaining is derived after normalization. |
| Only remaining percentage is present | Used is derived after normalization. |
| Percentage is outside the valid range | It is clamped to `[0, 100]`. |
| Percentage is non-numeric or non-finite | It does not cross the JSON-safe model boundary. |
| No usage adapter exists | `unsupported` is returned and Flutter hides the disclosure. |
| Credential needs sign-in | `auth_required` is returned with no raw provider error. |
| Response request or provider instance does not match the pending request | The client ignores it. |

## OpenCode Go adapter

| Scenario | Expected result |
|---|---|
| Account returns rolling, weekly, and monthly windows | Exactly Session, Weekly, and Monthly cross the protocol with used percentages and UTC reset timestamps. |
| `rolling` is absent | Only Weekly and Monthly render; no Session placeholder is created. |
| `percent` is zero | The window renders as 0% used / 100% remaining. |
| Row omits `resetsAt` | The row renders without a reset line. |
| Payload contains no usable window | The result is `unavailable` with a Retry affordance, never an empty card. |
| Endpoint returns `401` or `403` | The result is `auth_required` and the provider card keeps its status. |
| Endpoint returns `404`, `429`, or `5xx` | The result is `unavailable`; Retry is offered. |
| Snapshot has zero reset credits | No reset action is rendered. |
| Instance uses an API key and usage needs a credential | `Update API key` opens the instance edit form; OAuth reconnect never starts. |
| Instance uses an account and usage needs a credential | `Reconnect` still runs the shared account re-authentication. |

## Freshness and concurrency

| Scenario | Expected result |
|---|---|
| Open Providers with configured instances | Provider cards render before support and usage requests complete. |
| Re-enter within one minute of authoritative `fetched_at` | Existing snapshot remains and no second usage fetch occurs. |
| Re-enter after one minute | Existing snapshot remains visible as stale while one background refresh runs. |
| Background refresh fails | Previous snapshot stays visible with an inline Retry or sign-in message. |
| Press Refresh repeatedly during one request | Only one request is sent for that instance and the button stays disabled. |
| Refresh account A while account B is visible | Only A is fetched. |
| Leave the page without interaction | No polling requests occur. |

## Widget presentation

| Scenario | Expected result |
|---|---|
| Unsupported instance | No `Usage & limits` disclosure or empty spacing. |
| First supported load | A small indicator appears inside the disclosure; the rest of the card remains usable. |
| Weekly used is 42% | The primary text is `58% remaining`; secondary text is `42% used`. |
| Monthly is absent | No Monthly label or placeholder appears. |
| A reset timestamp is supplied in UTC | Relative text uses local time and the tooltip exposes the full local timestamp. |
| Snapshot is refreshing | Old window rows remain visible with a non-destructive refreshing indicator. |
| Typed transient failure | Concise English text and Retry are visible; raw provider response is absent. |
| Typed authentication failure | English sign-in guidance is visible without changing the provider readiness badge. |

## Reset mutation coverage (Gates D–E)

Reset verification covers positive-credit visibility, zero-credit hiding,
preflight exhaustion checks, confirmation-required and forced confirmation
paths, idempotent duplicate submission, typed reset outcomes, forced
post-success refresh, and strict credential isolation between instances. The
focused agent protocol tests exercise concurrent same-key requests and account
credential scoping; Flutter state/widget tests exercise double-submit,
confirmation, count visibility, and authoritative snapshot replacement.

## Reset matrix

- Verify no reset button at zero credits and correct singular/plural count above zero.
- With an exhausted window, verify the normal confirmation, one POST, disabled double-submit, and replacement by the refreshed snapshot.
- With no exhausted window, verify the first request performs no POST and returns the warning; cancel consumes nothing; **Reset anyway** uses the short-lived confirmation token.
- Replay the same idempotency key and verify no second credit is consumed.
- Change the provider snapshot between warning and confirmation and verify a new confirmation is required.
- Verify `nothing_to_reset`, `no_credit`, `already_redeemed`, auth, network failure, and successful-reset/failed-refresh messaging.
- Repeat with two configured ChatGPT accounts and verify credentials, snapshots, confirmation tokens, and resets never cross instance ids.


## Live OpenCode Go acceptance

Use a matched managed runtime with an isolated Sanad Home and a driver-enabled
Client. Store the OpenCode Go API key in the Agent vault; never paste it into a
command, log, or screenshot. The acceptance surface is Settings → Providers.

1. Open `Usage & limits` for a READY API-key instance. Expect Session, Weekly,
   and Monthly with used/remaining values and reset text; expect no reset action
   when the snapshot reports zero reset credits.
2. Edit the instance, choose `Replace or remove key` → `Replace with new key`,
   store a deliberately invalid key, and save.
3. Expect `NEEDS_AUTH`, the credential-rejected message, and a disclosure that
   says `Update this provider's API key to view usage limits.` with an
   `Update API key` action. No `Reconnect` action or OAuth flow may start.
4. Activate `Update API key`. Expect `Edit Provider Instance`; replace the key
   with the valid vault value and save.
5. Expect `READY` and `Key accepted: <n> models`; reopen `Usage & limits` and
   expect all three windows to return. A later refresh may move a window's used
   percentage while the page stays on the same instance.

Acceptance run on 2026-11-13 observed Session `2%` → `3%` used, Weekly `55%`,
Monthly `55%`, resets of `2 h`, `2 d`, and `Mon, Nov 23, 17:03`, and no reset
action at zero credits. The API-key recovery path behaved exactly as above.

## Automated daemon-backed fixture

`client/e2e_test/local_dual_connection_e2e_test.dart` spawns the real daemon
with isolated state and credential homes, connects through the local WebSocket,
creates an `openai-codex` instance, and points it at a loopback HTTP fixture. The
test verifies capability discovery, usage parsing, authorization scoping, one
reset mutation, and forced post-reset reconciliation. It never contacts the
production ChatGPT endpoint or reads live provider credentials.
