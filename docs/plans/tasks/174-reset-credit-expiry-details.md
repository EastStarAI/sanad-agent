---
title: "Task 174: Reset credit expiry details"
description: "Show each available ChatGPT reset credit separately with its local expiration time instead of a single combined count."
status: "in_progress"
priority: "medium"
scope: "Agent ChatGPT usage adapter and snapshot model, Client reset controls, localization, protocol, QA and task documentation"
depends_on: "Task 55 provider account usage limits"
coordinates_with: "Task 55"
---

# Task 174 — Reset credit expiry details

**Status:** in progress
**Owners:** `agent/lib/core/provider_usage/` and
`client/lib/features/provider_setup/`
**Contract:** [provider protocol](../../technical/provider_protocol.md),
[product behavior](../../product/provider_account_usage_limits.md)

## Goal

When ChatGPT reports multiple banked reset credits, show each available credit
as its own row with its local expiration time instead of collapsing them into a
single `N resets available` line. The reset action stays one shared control.

## Locked decisions and scope

- Only the ChatGPT/Codex usage payload exposes
  `rate_limit_reset_credits.credits[]`. OpenCode Go reports no reset credits and
  keeps its current usage-only card.
- Parse only credits whose `status` is `available` or absent, and only when
  `expires_at` is a valid timestamp. Sort by earliest expiry.
- The snapshot carries display-safe timestamps only (`expires_at`,
  `granted_at`); provider `title`, `description`, profile ids, account ids, and
  raw payloads never cross the protocol.
- The Client renders a localized generic `Reset credit` label with the local
  expiration date/time. It never echoes the provider's English `title`.
- The detailed list replaces the combined count line when present. When the
  list is absent but `available_resets > 0`, keep the existing combined line as
  a backward-compatible fallback.
- The existing single `Reset limits` button and reset mutation stay unchanged;
  no per-credit reset button is introduced.
- No live UI test is part of this task. Verification is analyzer plus focused
  agent and widget tests.

## Gates

### G0 — Discovery

- [x] Confirm the daemon currently parses only
      `rate_limit_reset_credits.available_count`.
- [x] Confirm the payload's `credits[]` entries carry `status` and
      `expires_at`/`granted_at`.
- [x] Confirm the Client and protocol carry only `available_resets`.

### G1 — Agent snapshot and adapter

- [x] Add `ProviderUsageResetCredit` with UTC `expiresAt`/`grantedAt` and
      snapshot `resetCredits`.
- [x] Serialize and parse `reset_credits` in the snapshot map without changing
      the existing `available_resets` behavior.
- [x] Parse, filter, sort, and attach available credits in the ChatGPT adapter.
- [x] Include reset credits in the reset confirmation fingerprint.

### G2 — Client DTO, controls, and localization

- [x] Add the Client reset-credit DTO and parse `reset_credits`.
- [x] Render one keyed row per credit with a localized expiry date/time.
- [x] Keep the combined count only as the no-detail fallback and preserve the
      shared reset button.
- [x] Add English and Arabic strings and regenerate localizations.

### G3 — Documentation and verification

- [x] Update the provider protocol snapshot contract.
- [x] Update product behavior and the QA runbook.
- [x] Add agent, DTO, and widget coverage.
- [x] Run agent and Client analyzers plus focused tests.

### G4 — Delivery

- [ ] Commit with a task-referenced message and push the branch.
- [ ] Open a draft pull request with the mandatory labels and exact
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
      then two separate rows show a localized expiry and no combined
      `N resets available` line.
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
- [ ] A draft pull request is open with the mandatory labels and exact
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
```
