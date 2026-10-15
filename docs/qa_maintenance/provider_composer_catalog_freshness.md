# Provider composer catalog freshness

## Automated acceptance

Run from `client/` using FVM:

```sh
fvm flutter test test/features/provider_setup/bloc/provider_usage_cubit_test.dart test/widget/provider_setup_flow_test.dart test/widget/conversation_input_panel_rebuild_test.dart --reporter expanded
fvm flutter analyze
```

The focused suite must prove:
- Create/rename/remove snapshots update composer labels from the shared per-device catalog.
- Catalog changes do not cancel unrelated usage/support requests; quiescent identical snapshots are no-ops.
- Authoritative empty or unchanged snapshots neutralize pending stale catalog responses.
- `clearDevice` preserves invalidation generations: a late pre-clear response cannot restore names, including rejoining the same device.
- Failed initial load followed by navigation/error clearing cannot publish an uninitialized empty catalog.
- A successful snapshot with a non-ready runtime still publishes valid instance names; runtime readiness text is not catalog authority.
- Rebuilds/remounts do not introduce repeated network requests, and devices remain isolated.

The implementation contract lives in `client/lib/features/provider_setup/AGENTS.md`; ownership/protocol details live in `docs/technical/provider_protocol.md`.

## Live acceptance — requires approved setup

Do not infer live acceptance from widget tests. Confirm the selected checkout, isolated runtime Home, target device and explicit Client VM selector before any mutation; never switch source, change credentials or create an extra stack implicitly.

| Scenario | Required observation |
|---|---|
| Create a reviewer-owned test provider instance | Composer exposes the new display name without Client restart. |
| Rename the same instance | Settings and composer agree immediately, without losing existing usage/support state. |
| Remove it, including the last-instance case on an isolated fixture | No stale name returns after delayed requests, navigation or reopen. |
| Failed setup load followed by Back/Picker | Previously valid labels survive; no fabricated successful empty snapshot. |
| Select a different device | No labels or pending responses cross the device boundary. |

Use only approved reviewer-owned test configuration. Record sanitized observations, command exits and event ordering; never store credentials, raw identities or request payloads. Thinking capability and wire acceptance are separate gates requiring the approved custom-model policy design; this page does not claim or enable them.
