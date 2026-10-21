---
title: "Agent Update Trust and Auto-Pairing QA"
description: "Automated coverage and isolated live scenarios for typed update trust diagnostics, Desktop Client–Agent auto-pairing, and stopped-agent compatibility validation."
---

# Agent Update Trust and Auto-Pairing QA

Design: [Release and Update Architecture](../technical/update_architecture.md)
and [Client Local Daemon Control](../technical/client_local_daemon_control.md).

## Automated coverage

| Area | Suite | Proves |
|---|---|---|
| Trust stages and sanitizer | `agent/test/core/update/platform_trust_diagnostics_test.dart` | codesign exit 3 → `publisher_requirement`, other exits → `codesign_verification`, launch failure or throw → fail-closed `verifier_unavailable`, metadata stage, Authenticode stage; artifact, `/private`, `HOME`, temp, `/var/folders`, and any-drive user paths removed; one bounded line |
| Agent update and CLI | same file | `trust_failed` message carries the summary without local paths and keeps the old executable; recovery guidance is POSIX or PowerShell by platform and names only `sanad.eaststarai.com` |
| Client bootstrap trust | `client/test/unit/services/verified_agent_bootstrap_installer_test.dart` | bootstrap `trustFailed` carries the typed sanitized stage and keeps the existing executable |
| Stopped-agent lifecycle | `client/test/unit/services/agent_compatibility_validation_test.dart` | the G5 scenarios against a version-faithful fake CLI (`client/test/helpers/fake_agent_cli.dart`): old/no service, old/registered, compatible reuse, clean install, trust/checksum failure, downgrade refusal, retry, Ubuntu v1.0.15 without sudo; plus legacy `service install --help` never used, rollback after failed start, newer agent started, kernel/OS version never parsed, prerelease kept, bounded hung probe, exact flag match, single registration on macOS/Windows, managed `SANAD_HOME`/`SANAD_SERVICE_INSTANCE` |
| Coordinator | `client/test/unit/services/device_connection_coordinator_test.dart` | running agent paired to the client version, stopped standalone agent handed to the controller, source agent started before the update query, single-flight, forced retry |
| Bootstrap pairing | `client/test/unit/bloc/gateway_connection_cubit_auto_pairing_test.dart` | a running older agent is paired during route bootstrap; a failed pairing still connects |

## Live scenarios

Never run these against the primary Sanad Home, its default service, or a
developer's live runtime. Every real install or registration uses a dedicated
Test Home and a unique service instance.

### Isolation for real install and registration

1. Create an absolute Test Home outside `~/.sanad`, for example under a
   disposable directory, and pick a unique instance such as `qa107`.
2. Build a release-mode Client (a debug or `sanad-dev` source run selects the
   source controller and never exercises the stopped-agent path) with
   `--dart-define=SANAD_HOME=<test-home>` and
   `--dart-define=SANAD_SERVICE_INSTANCE=qa107`. The Client passes both to every
   agent process, so registration creates only
   `com.eaststarai.sanad.agent.qa107`, `sanad-agent-qa107.service`, or the
   `SanadAgent-qa107` task.
3. Seed `<test-home>/bin/sanad` (`sanad.exe` on Windows) with the official
   older release under test, downloaded from its canonical GitHub Release
   asset and checked against the published SHA-256.
4. Afterwards run `<test-home>/bin/sanad service uninstall` with
   `SANAD_HOME=<test-home>` and `SANAD_SERVICE_INSTANCE=qa107`, and confirm
   the default service is unchanged before deleting the Test Home.

### Scenarios

| # | Setup on the Test Home | Action | Expected |
|---|---|---|---|
| L1 | Ubuntu, v1.0.15 executable, no service | **Run Sanad Locally** | no sudo/pkexec prompt; executable replaced by the Client version; `sanad-agent-qa107.service` registered with `--user-scope`; health reports the Client version; local socket ready |
| L2 | macOS or Linux, older executable, instance service registered, stopped | **Run Sanad Locally** | executable replaced; existing registration reused; ready at the Client version; no `sanad.rollback` left once healthy |
| L3 | older agent running from the Test Home service | restart the Client | bootstrap updates through `/update` before connecting; ready at the Client version |
| L4 | executable newer than the Client, stopped | **Run Sanad Locally** | executable unchanged; agent started and usable; the step completes (no `[ERROR]`, no failure) with the `[INFO]` notice "The installed agent <agent version> is newer than this client <client version>. It was kept and is in use; update the client when convenient." (Arabic in the Arabic locale); the local device's Settings page shows the same notice |
| L5 | v1.0.0–v1.0.4 executable, Linux | **Run Sanad Locally** | no service registered before replacement (inspect `systemctl --user list-units 'sanad-agent*'` and the system unit list); replaced and registered once |
| L6 | macOS, `SANAD_RELEASE_ARTIFACT_MIRROR_URL` build pointing at a mirror serving a re-signed or unsigned candidate with matching manifest size/SHA-256 | **Run Sanad Locally** or `sanad update` | `trust_failed` with `stage=publisher_requirement` or `stage=codesign_verification`; no user path in the message; previous executable unchanged |
| L7 | any trust failure from L6 via `sanad update` | read the CLI output | the platform-appropriate official installer command and the service-restart warning |

L1–L5 need a real install or registration and therefore the isolation above.
L6 needs a private mirror candidate as described under isolated candidate
verification in the update architecture; it never touches a public release.
