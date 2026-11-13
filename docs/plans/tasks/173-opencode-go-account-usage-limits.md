---
title: "Task 173: OpenCode Go account usage limits"
description: "Show OpenCode Go account usage windows in the existing instance-scoped Usage & limits surface, with API-key-correct recovery."
status: "in_review"
priority: "medium"
scope: "Sanad agent provider usage adapter, Client usage recovery action, documentation and QA"
depends_on: "Task 55 provider account usage limits"
coordinates_with: "Task 29 provider instance runtime"
reference_grounding: "E173"
evidence_id: "E173"
packet_fingerprint: "sha256:fb380adeb8f4f69dce4bae180d66b8833ec11e3a07b86fcfdf463309b7047f19"
---

# Task 173 — OpenCode Go account usage limits

**Status:** implemented and live-verified — draft PR #425; all required CI checks pass
**Owners:** `agent/lib/core/provider_usage/` and
`client/lib/features/provider_setup/`
**Contract:** [provider protocol](../../technical/provider_protocol.md),
[product behavior](../../product/provider_account_usage_limits.md)

## Goal

Show the configured OpenCode Go account's 5-hour, weekly, and monthly usage
windows inside the existing `Usage & limits` disclosure, using the same
daemon-owned, instance-scoped contract as ChatGPT, and keep the recovery
action correct for an API-key provider.

## Locked decisions and scope

1. The daemon owns the fetch and the snapshot; the Client never reads the API
   key or contacts the provider.
2. The adapter is registered for the exact `opencode-go` template id. Support
   continues to flow only through `ProviderUsageRegistry`.
3. The usage request uses one canonical account endpoint and the instance's
   API key. It does not reuse the configured model base URL.
4. `rolling` maps to the existing `session` window type (the provider's 5-hour
   window), alongside `weekly` and `monthly`. No new protocol window type.
5. `percent` is consumed usage. Windows without a numeric percent are omitted;
   no placeholder rows. All-invalid payloads surface `unavailable`.
6. OpenCode Go exposes no reset credits and no plan name. `available_resets`
   stays `0` and no reset adapter is registered.
7. `auth_required` for an API-key instance renders an `Update API key` action
   that opens the instance edit flow. Account instances keep `Reconnect`.
8. Window labels resolve from the typed window type in the Client, falling back
   to the daemon label for unknown types.
9. Per-model breakdown, paused/depleted status text, overage display, and
   plan names are out of scope.

## Gates

### G0 — Evidence and discovery

- [x] Locate the provider's account-usage endpoint and payload in a pinned
      reference revision.
- [x] Confirm percent semantics, window omission, reset timestamp handling, and
      failure containment against reference tests and provider documentation.
- [x] Author evidence packet `E173` and pin the source revision.
- [x] Confirm the existing Sanad usage contract needs no protocol or model
      change.

### G1 — Daemon adapter

- [x] Add the OpenCode Go usage adapter with defensive parsing and typed
      failures.
- [x] Extract shared percentage/reset parsing so both adapters use one owner.
- [x] Register the adapter in the usage registry.
- [x] Add focused adapter and registry tests.

### G2 — Client recovery and labels

- [x] Render `Update API key` for API-key `auth_required` and keep `Reconnect`
      for account instances.
- [x] Localize window labels by typed window type with a daemon-label fallback.
- [x] Add English and Arabic strings.
- [x] Add widget coverage for both recovery actions and localized labels.

### G3 — Documentation and verification

- [x] Update product, protocol, provider-runtime, Client, and QA documentation.
- [x] Run the agent analyzer and focused tests.
- [x] Run the Client analyzer.
- [x] Execute the Client widget suite on a desktop-capable host. CI's `Test client` lanes passed; this host still cannot build the `cnativeapi` native asset (no GTK 3 / X11 / Xi development headers or `pkg-config`).
- [x] Record the audit result against the evidence packet obligations.
- [ ] Update the graph (no `graphify` CLI or graph output exists in this
      checkout).

### G4 — Delivery

- [x] Commit with a plan-referenced message and push the branch.
- [x] Open a draft pull request with problem, changes, and exact verification.

## Acceptance Criteria

- [x] Given an OpenCode Go instance with a valid API key, when usage is
      requested, then the snapshot contains exactly the provider-returned
      Session, Weekly, and Monthly windows with used percentages and UTC reset
      timestamps.
- [x] Given a payload missing one window or containing a non-numeric percent,
      when usage is requested, then only valid windows cross the protocol and no
      placeholder appears.
- [x] Given a `401` or `403`, when usage is requested, then the result is
      `auth_required` and the instance status is unchanged.
- [x] Given an API-key instance in `auth_required`, when the disclosure renders,
      then it offers `Update API key` and never starts OAuth reconnect.
- [x] Given an account instance in `auth_required`, when the disclosure renders,
      then it still offers `Reconnect`.
- [x] Given an available snapshot with zero reset credits, when the disclosure
      renders, then no reset action appears.
- [x] Automated coverage proves the mapping, omission, clamping, failure
      containment, capability registration, and both recovery actions.

## Live acceptance (2026-11-13)

Run from worktree `173-opencode-go-account-usage` with the managed runtime,
isolated Sanad Home, Xvfb display, and the Flutter driver. The provider used the
real OpenCode Go API key from the Agent vault; the key was injected into the
interactive field through the vault and was never printed in command output or
logs.

Observed on the first valid-key snapshot:

- Session: `2% used`, `98% remaining`, `Resets in 2 h`.
- Weekly: `55% used`, `45% remaining`, `Resets in 2 d`.
- Monthly: `55% used`, `45% remaining`, `Resets on Mon, Nov 23, 17:03`.
- No reset action was rendered at zero reset credits.

Recovery check:

1. Opened `Edit Provider Instance`, chose `Replace with new key`, stored an
   invalid key, and saved.
2. The instance became `NEEDS_AUTH`, showed
   `The provider rejected this credential. Update the API key, then test the
   connection again.`, and the disclosure showed
   `Update this provider's API key to view usage limits.` with an
   `Update API key` action. No `Reconnect` action and no OAuth flow started.
3. `Update API key` opened `Edit Provider Instance`, confirming the API-key
   recovery path.
4. Replaced the invalid key with the valid vault key and saved. The instance
   returned to `READY` (`Key accepted: 30 models`), and the disclosure restored
   Session, Weekly, and Monthly. The refreshed Session reading was `3% used`,
   `97% remaining`, `Resets in 1 h`; Weekly and Monthly remained `55% used` /
   `45% remaining`.

The edit-mode `New API Key` field received the stable key
`provider_new_api_key_field` so this recovery path stays interactively
testable.

## Definition of Done

- [x] `agent` analyzer and focused usage/provider tests pass.
- [x] `client` analyzer passes.
- [x] Client widget tests pass (CI `Test client` lanes).
- [x] Documentation and owning contracts describe the new adapter and the
      API-key recovery rule.
- [x] The evidence-packet obligations are audited in the local run record.
- [ ] `graphify update .` completes (tool unavailable in this checkout).
- [x] A draft pull request is open with the exact verification results.

## Verification log

```text
fvm dart analyze                          # agent: no issues
fvm dart test test/core/provider_usage    # 61 passed
fvm dart test test/interfaces/sanad_bridge_provider_usage_test.dart  # 9 passed
fvm flutter analyze                       # client: no issues
fvm flutter test test/features/provider_setup/widgets/provider_usage_section_test.dart
  # 10 passed after installing host GTK 3 / X11 / Xi development packages
sanad-dev run --background --driver --no-cloud  # matched agent/client runtime
sanad-dev ui ...                        # live OpenCode Go usage + auth_required
                                        # recovery acceptance (values above)
GitHub Actions PR #425                  # 24 checks passed, 0 failed
  # Test client (1/4)-(4/4) passed; rerun on the final keyed-field commit
```
