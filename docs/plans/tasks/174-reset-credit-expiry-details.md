---
title: "Task 174: Reset credit expiry details"
description: "Show each available ChatGPT reset credit separately with its local expiration time instead of a single combined count."
status: "in_review"
priority: "medium"
scope: "Agent ChatGPT usage adapter and snapshot model, Client reset controls, localization, protocol, QA and task documentation"
depends_on: "Task 55 provider account usage limits"
coordinates_with: "Task 55"
---

# Task 174 — Reset credit expiry details

**Status:** in review — draft PR #441
**Owners:** `agent/lib/core/provider_usage/` and
`client/lib/features/provider_setup/`
**Contract:** [provider protocol](../../technical/provider_protocol.md),
[product behavior](../../product/provider_account_usage_limits.md)

## Goal

When ChatGPT reports multiple banked reset credits, show each available credit
as its own row — title, relative expiry, and that row's own reset action —
instead of collapsing them into a single `N resets available` line.

## Locked decisions and scope

- Only the ChatGPT/Codex account exposes reset credits, and its per-credit list
  comes from its own document (`GET
  /backend-api/wham/rate-limit-reset-credits`), not from `credits[]` inside
  `/usage`. OpenCode Go reports no reset credits and keeps its current
  usage-only card.
- Parse only credits whose `status` is `available` or absent, and only when
  `expires_at` is a valid timestamp. Sort by earliest expiry.
- The snapshot carries display-safe timestamps (`expires_at`, `granted_at`) and
  an opaque `credit_id` used only to target a redemption; provider `title`,
  `description`, `reset_type`, profile ids, account ids, and raw payloads never
  cross the protocol.
- The Client renders a localized generic `Reset credit` label with a relative
  expiry (`Expires in 2 d 5 h`) and shows the exact local date/time only in the
  expiry tooltip, formatted with the current app locale. It never echoes the
  provider's English `title`, and it does not map `reset_type` slugs to titles,
  because the references document only `codex_rate_limits` with no full/partial
  enumeration.
- The detailed list replaces the combined count line when present. When the
  list is absent but `available_resets > 0`, keep the existing combined line as
  a backward-compatible fallback.
- Each credit row carries its own `Reset limits` action, and each action redeems
  that row's credit through its opaque `credit_id`; the row action is not a new
  mutation, only a target for the existing one. The credit id is never
  displayed, never in a tooltip, and never logged, and the consume command keeps
  working without it so an older Client is unaffected. Per-credit applicability
  is absent from the provider payload, so the shared `applicable_resets` rule
  disables every row action together. When a snapshot's rows arrive without any
  `credit_id` (an older daemon), the disclosure falls back to the single action
  on the first row instead of advertising a target it cannot honour.
- A credit past its `expires_at` is dropped by the adapter, and the Client still
  defends against a stale row by reading `Expired` and disabling that action
  rather than showing an imminent countdown.
- No live UI test is part of this task. Verification is analyzer plus focused
  agent and widget tests.

## Gates

### G0 — Discovery

- [x] Confirm the daemon only read
      `rate_limit_reset_credits.available_count` and never requested the
      per-credit document.
- [x] Confirm the per-credit list is a **separate** ChatGPT document
      (`GET /backend-api/wham/rate-limit-reset-credits`), not a `credits[]`
      array inside `/usage`. Reference-derived shapes are pinned by
      `agent/test/fixtures/chatgpt_usage_reference_shape.json` (count plus
      `applicable_available_count`, no credit array) and
      `agent/test/fixtures/chatgpt_rate_limit_reset_credits_reference_shape.json`
      (the detail document). Both are reverse-engineered, so a live capture
      still confirms `status`, `expires_at`, and `granted_at`; a renamed field
      drops every credit and the Client falls back to `N resets available`.
- [x] Confirm the Client and protocol carried only `available_resets`.
- [x] Treat `applicable_available_count` as a real provider field: `0` means
      credits exist but none can be applied, so the Client disables the reset
      action and explains why instead of offering a request that must fail.

### G1 — Agent snapshot and adapter

- [x] Add `ProviderUsageResetCredit` with UTC `expiresAt`/`grantedAt` and
      snapshot `resetCredits`.
- [x] Serialize and parse `reset_credits` in the snapshot map without changing
      the existing `available_resets` behavior.
- [x] Parse, filter, sort, and attach available credits in the ChatGPT adapter.
- [x] Include reset credits in the reset confirmation fingerprint.
- [x] Keep the usage command mapping in
      `agent/lib/interfaces/platforms/sanad_gateway/handlers/provider_usage_command_mapper.dart`
      so `provider_command_handler.dart` stays under the 1,000-line size ratchet
      without an allowlist entry.

### G2 — Client DTO, controls, and localization

- [x] Add the Client reset-credit DTO and parse `reset_credits`.
- [x] Render one keyed row per credit with a relative expiry and the full local
      date/time in its tooltip.
- [x] Keep the combined count only as the no-detail fallback, and keep it as a
      single action with no `credit_id`.
- [x] Add English and Arabic strings and regenerate localizations.

### G3 — Documentation and verification

- [x] Update the provider protocol snapshot contract.
- [x] Update product behavior and the QA runbook.
- [x] Add agent, DTO, and widget coverage.
- [x] Run agent and Client analyzers plus focused tests.

### G4 — Delivery

- [x] Commit with a task-referenced message and push the branch.
- [x] Open a draft pull request with the mandatory labels and exact
      verification.

## Acceptance Criteria

- [x] Given two available credits with distinct `expires_at` values, when usage
      is fetched, then the snapshot contains two reset credits sorted by
      earliest expiry.
- [x] Given a credit whose status is not available or whose expiry is missing
      or malformed, when usage is fetched, then that credit is omitted and the
      reset count remains authoritative.
- [x] Given a snapshot with reset credits, when it round-trips through the
      protocol map, then `reset_credits` preserves both timestamps in UTC.
- [x] Given a Client snapshot with two credits, when the disclosure renders,
      then two rows stack a relative expiry over a trailing action each and no
      combined `N resets available` line appears.
- [x] Given a credit row whose action is pressed, then the reset command carries
      that row's `credit_id`, and the id never appears in the UI or a log.
- [x] Given `available_resets > 0` with no detailed credits, when the
      disclosure renders, then the existing combined count fallback remains.
- [x] Arabic and English copy both resolve through localization; no provider
      English title or account identifier is shown.
- [x] Automated coverage proves parsing, filtering, sorting, serialization,
      rendering, fallback, and localization.

## Definition of Done

- [x] `agent` analyzer and focused usage tests pass.
- [x] `client` analyzer and focused widget tests pass.
- [x] Protocol, product, QA, and this task document are current.
- [x] No live UI test is run for this task.
- [x] A draft pull request is open with the mandatory labels and exact
      verification results.

## Verification log

```text
fvm dart analyze                                  # agent: no issues
fvm dart test test/core/provider_usage            # 42 passed
fvm dart test test/interfaces/sanad_bridge_provider_usage_test.dart  # 9 passed
fvm flutter analyze                               # client: no issues
fvm flutter test test/features/provider_setup/widgets/provider_usage_section_test.dart test/features/provider_setup/data/provider_usage_dto_test.dart
  # 12 passed
fvm flutter test test/features/provider_setup/bloc/provider_usage_cubit_test.dart  # 26 passed
# No live UI test was run for this task, per scope.
Draft PR #441                            # type/feature, comp/agent, comp/client,
                                        # comp/providers, comp/docs, size/medium
```
