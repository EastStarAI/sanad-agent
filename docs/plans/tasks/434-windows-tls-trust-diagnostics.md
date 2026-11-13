# Task 434 — Windows TLS trust diagnostics for release fetches

Owning Issue: #434 — `bug(install): Windows "Run local" aborts on a TLS trust failure and shows a raw BoringSSL error`

## Goal

A Windows Client whose trust set does not cover the release host's chain reports a distinct, localized, actionable install outcome instead of a raw BoringSSL dump, and the same machine can be unblocked without weakening certificate verification.

## Locked decisions and scope

- **Classify, do not swallow.** A TLS failure while fetching the release manifest or the Agent artifact becomes `AgentBootstrapStatus.tlsTrustFailed` and surfaces as `AgentLifecycleStatus.tlsTrustFailed`. The raw exception stays in Client logs only.
- **Never weaken verification.** No `badCertificateCallback`, no redirect to plain HTTP, no unverified artifact path. Existing size, SHA-256, version, and platform-trust checks are untouched.
- **Explicit extra trust only.** `SANAD_EXTRA_CA_BUNDLE` names a PEM bundle of roots the operator chooses to trust (antivirus or corporate interception root). It is additive to the platform roots (`withTrustedRoots: true`) and never replaces them. An unreadable or malformed bundle is logged and ignored; it never fails an install.
- **Out of scope:** a mirrored manifest host. A machine that cannot build a trusted chain to `github.com` cannot build one to our own host either, so a mirror would not have fixed the reported failure. It stays a separate, unapproved follow-up in #434.
- **Runtime (dictation) archive:** a TLS failure there keeps the existing `downloadFailed` dictation-only outcome. The Agent is already verified and installed at that point, and the runtime never turns a successful install into a failure.

## Gates

### G0 — Discovery
- [x] Reproduce the reported failure path from source: `verified_agent_bootstrap_installer.dart` manifest fetch and its error wrapping.
- [x] Confirm `package:http` `IOClient` passes `HandshakeException` through unchanged, so `on TlsException` classifies it deterministically.
- [x] Confirm the release surfaces are healthy and byte-identical, so the failure is machine trust only.

### G1 — Classification and extra trust
- [x] Add `createReleaseTrustHttpClient()` in `client/lib/infrastructure/platform/`.
- [x] Add `AgentBootstrapStatus.tlsTrustFailed` and classify manifest plus artifact TLS failures.
- [x] Add `AgentLifecycleStatus.tlsTrustFailed` and map it in `StandaloneDaemonController`.

### G2 — Localized outcome
- [x] Add `agentInstallTlsTrustFailed` to `app_en.arb` and `app_ar.arb`.
- [x] Render the localized text in `InstallationTerminalView` and pass it to `onFailure`.

### G3 — Coverage
- [x] Deterministic unit coverage for classification and for a missing, malformed, and absent bundle.
- [x] Self-signed loopback TLS regression proving the same request fails closed without the bundle and succeeds with it.

### G4 — Documentation
- [x] Windows TLS trust troubleshooting runbook in `docs/qa_maintenance/`.
- [x] `SANAD_EXTRA_CA_BUNDLE` and the classification recorded in `docs/technical/update_architecture.md`.
- [x] Index entries in `docs/llms.txt` and `docs/qa_maintenance/MOC.md`.

## Acceptance Criteria
- [ ] A `HandshakeException` on the manifest fetch yields `tlsTrustFailed` with no download attempt and no raw exception text in the user-facing message.
- [ ] A `HandshakeException` on the Agent artifact fetch yields `tlsTrustFailed` and leaves any installed executable untouched.
- [ ] With `SANAD_EXTRA_CA_BUNDLE` pointing at the loopback server's own certificate, the manifest and artifact fetch succeed and the install completes.
- [ ] Without the bundle, the same loopback server produces `tlsTrustFailed` — proving nothing is bypassed.
- [ ] A missing or malformed bundle is ignored with a logged warning, and the request still verifies normally.
- [ ] `fvm flutter analyze` is clean and the focused suites pass.

## Definition of Done
- [ ] Analyzer clean for `client/`.
- [ ] Focused tests: new TLS/trust suite plus the existing bootstrap installer suite.
- [ ] Arabic and English labels carry equivalent meaning.
- [ ] No absolute paths, no secrets, and no tracked PEM material in tests.

## Current status

G0–G4 implemented; delivering as a draft pull request. No remaining gates beyond review.
