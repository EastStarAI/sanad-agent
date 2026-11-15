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
| ChatGPT reports `rate_limit_reset_credits.available_count` above zero | The adapter also requests `GET /backend-api/wham/rate-limit-reset-credits` with the same headers; the per-credit rows come from that document only. |
| ChatGPT reports a zero credit count | Exactly one request is made; no detail request is sent. |
| The reset-credit detail request fails (non-2xx, non-JSON, or transport error) | The snapshot still returns `available` with the authoritative count and no rows. |
| The detail document lists redeemed, expired, or undated credits | Only `available` entries with a parseable, still-future `expires_at` cross the protocol, earliest expiry first; an `available` credit whose timestamp has passed is dropped too. |
| `/usage` omits `applicable_available_count` | The snapshot omits `applicable_resets`, and the client keeps the reset action enabled. |
| `/usage` reports `applicable_available_count` of zero | `applicable_resets` is `0`, and the client disables the action while keeping the credit rows. |

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
| Two reset credits have distinct expiries | Two `Reset credit` rows render, each stacking the title over a relative `Expires in 2 d 5 h` line with its own trailing `Reset limits` action; the combined count is hidden while the row count equals `available_resets`, and reappears above the rows when they disagree. |
| A credit row renders normally | No absolute date/time is visible; hovering the relative expiry reveals the full local instant formatted in the current app language (an Arabic card never shows `Dec`). |
| Each row has its own action | Pressing row *n* consumes that row's credit: the request carries that credit's `credit_id`, and the id never appears in the UI, a tooltip, or a log. |
| The rows arrive without `credit_id` (an older daemon) | The rows still render, but only the first row carries the single action; pressing it sends the original untargeted request instead of promising a per-row target. |
| A row's `expires_at` is already past | The expiry reads `Expired` (localized) rather than an imminent countdown, and that row's action is disabled. |
| Only `available_resets` is supplied | The existing combined `N resets available` fallback remains, with a single action and no `credit_id`. |
| Snapshot reports `applicable_resets` of zero | The credit rows still render, every row action is disabled, and the localized `This reset credit cannot be applied right now.` hint appears directly under the first row; no confirmation or reset request is possible. |
| Snapshot omits `applicable_resets` | The actions stay enabled exactly as before the field existed. |
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
confirmation, per-row credit targeting, relative expiry rendering, fallback
count visibility, and authoritative snapshot replacement.

## Reset matrix

- Verify no reset button at zero credits and correct singular/plural count above zero.
- With two available credits, verify two `Reset credit` rows stacking the title over a relative `Expires in …` line with a trailing action each; verify no absolute date is visible, the tooltip shows the full local instant in the app language, and no combined count appears while the row count equals `available_resets`; verify the combined count reappears above the rows when they disagree, and that a count-only payload still shows `N resets available` as the fallback.
- Press the second row's action and verify the consume request targets that credit (`credit_id`) while the first credit stays available; confirm the id never appears in the UI or a log.
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
Monthly `55%`, resets of `1 h`, `2 d 22 h`, and `Mon, Nov 23, 17:03`, and no
reset action at zero credits. The countdown rendered a single `Resets` prefix.
The API-key recovery path behaved exactly as above.

## Live ChatGPT reset-credit acceptance

Use one configured ChatGPT account with at least one available reset credit. The
Agent log must show request paths only; never paste the response, the
`Authorization` header, or any account identifier into a report or screenshot.

1. Confirm the daemon issues **two** requests: `GET
   /backend-api/wham/usage` and then `GET
   /backend-api/wham/rate-limit-reset-credits`. The first document carries only
   `rate_limit_reset_credits.available_count` (and, on some accounts,
   `applicable_available_count`); the per-credit list must come from the second
   document. If the rows are missing while the count is above zero, the second
   request is the first place to inspect.
2. When `/usage` reports `applicable_available_count: 0`, expect the credit rows
   to stay visible, `Reset limits` to be disabled, and the hint `This reset
   credit cannot be applied right now.` to appear. A disabled action must never
   reach the daemon: no confirmation dialog and no
   `rate-limit-reset-credits/consume` request.
3. When the field is absent, the actions stay enabled and behave exactly as
   before this field existed.
4. Confirm the snapshot never surfaces provider `title`, `description`, or
   `reset_type` values, that only `available` credits with an expiry are listed,
   and that the opaque credit id appears only in the `/consume` request body,
   never in the UI or a log.
5. Press one credit row and confirm the `POST
   /backend-api/wham/rate-limit-reset-credits/consume` body carries that row's
   `credit_id` with the idempotency key, and that the response reports
   `windows_reset` (a single consumed credit does not restore every window).

## Automated daemon-backed fixture

`client/e2e_test/local_dual_connection_e2e_test.dart` spawns the real daemon
with isolated state and credential homes, connects through the local WebSocket,
creates an `openai-codex` instance, and points it at a loopback HTTP fixture. The
test verifies capability discovery, usage parsing, authorization scoping, one
reset mutation, and forced post-reset reconciliation. It never contacts the
production ChatGPT endpoint or reads live provider credentials.
