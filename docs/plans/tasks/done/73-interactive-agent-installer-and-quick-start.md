# Task 73 — Interactive Agent Installer and Quick Start

## Goal Description

Make standalone Sanad Agent installation understandable and safe for both
interactive users and unattended environments. The canonical installers must
use a creation-time pairing token when the Client-generated command supplies
one, otherwise offer portal sign-in on an interactive terminal, and allow the
user to continue in local-only mode. Service lifecycle handling must ensure
that newly stored authentication and newly installed binaries are loaded by
the daemon without attempting to restart a service that has not been installed.

The public README files must separately explain the local desktop, remote
device/server, and contributor workflows. Pairing-token placeholders must not
be presented as commands users are expected to construct manually; the Client
owns generation of the token-bearing Add Device command.

## Implementation

- Extend the macOS/Linux and Windows installers with explicit login and
  no-login modes while retaining the Client-generated pairing-token mode.
- Prompt for portal sign-in only when the installer has an interactive input
  channel. Unattended installation must not block and must default to
  local-only operation unless an explicit login option is supplied.
- Authenticate before starting a clean service. Register and start a new
  service, but refresh an existing service so it loads the replacement binary
  and any newly persisted authentication.
- Keep pairing tokens secret and creation-only. Never accept or expose the
  durable device credential.
- Add focused installer contract coverage for authentication choices,
  non-interactive behavior, and service lifecycle ordering.
- Reorganize the English and Arabic quick starts into independent user and
  developer paths, and align the user guide and release verification contract.

## Definition of Done

- [x] A Client-generated command containing a pairing token prepares pairing
      before the service is started.
- [x] A tokenless interactive install offers portal sign-in or local-only use.
- [x] A tokenless unattended install does not wait for input.
- [x] Explicit login and no-login modes are documented and mutually safe.
- [x] A clean installation registers and starts the service without an invalid
      restart attempt.
- [x] Reinstalling or upgrading an existing service refreshes it after binary
      replacement and authentication changes.
- [x] README.md and README.ar.md clearly separate local users, remote users,
      and source developers without literal pairing-token commands.
- [x] User and release/QA documentation describe the same installer contract.
- [x] Focused tests and the Agent analyzer pass.
- [x] Graphify is updated after source changes.
- [x] Changes remain uncommitted until human review and approval.

## Success Test Scenario

```bash
cd agent
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test test/guards/installer_pairing_contract_guard_test.dart test/core/auth_test.dart 2>&1 | tail -5
cd ..
sh -n scripts/install.sh
graphify update .
git diff --check
```

Manual release-host verification must additionally cover:

1. clean pairing-token installation;
2. clean portal-login installation;
3. clean local-only installation;
4. unattended tokenless installation;
5. reinstall/upgrade of a running service; and
6. cancelled or failed login with executable rollback.

## Verification Evidence

- `sh -n scripts/install.sh` — passed.
- `fvm dart analyze` in `agent/` — passed with no issues.
- Focused installer/auth tests — all 8 passed.
- `git diff --check` — passed.
- `graphify update .` — completed after synchronization with `origin/main`
  (16,877 nodes, 22,869 edges).
- Native PowerShell parsing was unavailable on the macOS verification host;
  Windows release-host validation remains required before publication.
