---
title: "Linux Agent Service Lifecycle"
description: "Technical contract for Linux service selection, ownership, installation transactions, and lifecycle reporting."
---

# Linux Agent Service Lifecycle

## Scope

This document defines the Agent-owned Linux service registration implemented by
`agent/lib/core/setup/`. Installer transaction and cloud-health behavior remain
owned by Task 81 G4; this page states only the parts of that transaction this
contract constrains — the Home and account a root install selects, the explicit
account override, the service account's access preflight, the credential-aware
health window, and what a failed attempt leaves behind.

## Typed service contract

Service operations return `ServiceOperationResult`; inspection returns
`ServiceStatus`. A status carries the selected scope and backend plus explicit
`installed`, `enabled`, and `running` projections. Its canonical state is one of
`Missing`, `InstalledStopped`, `Running`, `Failed`, or `ManagerUnavailable`.
Command failures preserve the first concise manager error instead of replacing
all failures with a permissions message.

The CLI in `agent/bin/service.dart` only validates and presents commands. Scope
selection, unit generation, process execution, ownership metadata, lifecycle,
and rollback remain in the core service layer.

## Linux backend selection

Default selection is capability-based and ordered:

1. A user systemd service is selected only when the user bus exists, linger is
   enabled and reverified, and `systemctl --user show-environment` succeeds with
   explicit `HOME`, `XDG_RUNTIME_DIR`, and bus address.
2. A system systemd unit is selected when systemd is present but the user
   manager is not durable. A non-root invocation uses sudo only for system
   registration while the unit runs as the invoking user. Every root invocation
   — direct, or entered through `sudo` — registers the fixed unprivileged
   `sanad-agent` account and its state home; `SUDO_USER` never selects the unit
   account. `--run-as-user <account>` is the one explicit override.
3. OpenRC is selected only when systemd is absent and native OpenRC commands are
   available. Unsupported init systems return `ManagerUnavailable` before a
   service definition is installed.

### One Home the service account can reach

A system unit runs as an account that is usually not the account that installed
it, so the artifact the unit executes must live where that account can reach it.
A root Linux installation therefore uses `/var/lib/sanad-agent` as its Sanad
Home instead of root's own `$HOME/.sanad`: `/root` is owner-only, and a unit
whose `ExecStart` names a path under it fails activation with `203/EXEC` after
the caller has already paid for the download and the device pairing. The
installer selects that Home itself, exports it so the verified binary, its
`login`, and its `service install` all resolve the same Home, and leaves an
existing populated root Home untouched instead of migrating it — that Home is
root's own passwd home, not the process `HOME`, which `sudo` may leave pointing
at the invoking account. An explicit `SANAD_HOME` always wins.

`SUDO_USER` is deliberately absent from that decision. The installer keys the
Home on the effective uid, so a root install entered through sudo and a direct
root install produce the same account and the same Home; a rule that consulted
`SUDO_USER` made the installer place the artifact for `sanad-agent` while the
unit named `ubuntu`, and the mismatch surfaced only after the device
authorization was spent. `agent/lib/core/setup/service_account_policy.dart` owns
that predicate for the Agent, and the installer suite asserts the two agree.

The rule is not a location allowlist. Before `sanad service install` writes a
definition it proves the account named in the unit can reach the paths that unit
names: it asks the kernel the same question systemd will ask, with `test -x` on
`ExecStart` and on `WorkingDirectory` executed as that account. `test -x` needs
search permission on every parent directory, so it fails exactly where activation
would. The preflight runs after the dedicated home's ownership is fixed and
before the definition is staged, so a refusal leaves no unit, no activation, and
no rollback behind, and its message names the account, the unreachable path, and
the remedy. A host that lacks the probing tool (`runuser` as root, `sudo`
otherwise) keeps installing: the probe is a guard, and the activation health
transaction still has to prove the service is running.

### Explicit account override (`--run-as-user`)

An operator who needs the system unit to run as an existing account names it:
`install.sh --run-as-user <account>`, or `sanad service install --run-as-user
<account>` together with the Home that account can reach. The account must exist
(`getent passwd`), the install must run as root, and the choice is never silent —
the installer prints the account and Home it will use. The installer places the
Home at that account's own `~/.sanad`, gives that account ownership of the tree
so the daemon can read the credentials pairing wrote, and passes the same account
to `service install`; the preflight above then still has to pass. A non-root
invocation may not name an account. `--run-as-user root` is accepted only when
asked for by name and prints a warning, because every Agent tool, MCP server, and
terminal task then inherits root's privileges.

### A surviving definition for another Home

A definition left behind for a different Home cannot be upgraded in place: the
Agent refuses it as a conflicting service, and that refusal used to arrive after
the download and the device authorization. `install.sh` therefore reads the
existing systemd or OpenRC definition before downloading anything and, when its
`SANAD_HOME` differs from the Home this run would use, stops with exit `71` and
prints the definition path, the Home it names, and the exact command that removes
it — the owned `service uninstall`, or the `systemctl disable --now` and `rm`
pair when the binary that owns it is gone.

### Explicit user scope (`--user-scope`)

When invoked with `--user-scope` (used by Client-initiated bootstrap), the
selector explicitly targets a systemd user unit without privilege escalation:

- It never invokes `sudo`, `pkexec`, or `loginctl enable-linger`.
- It never falls back to a system systemd unit or OpenRC.
- An active user bus (requiring the `/run/user/<uid>/bus` socket and supplying
  the derived environment) and a successful `systemctl --user show-environment`
  probe are sufficient, even when `Linger=no`. It does not accept an arbitrary
  `DBUS_SESSION_BUS_ADDRESS` independently.
- Because linger is not modified, the service operates within the active user
  session and requires an interactive user login to restart after logout or reboot.
- If the user bus or systemd user manager probe fails, or if invoked as root,
  installation fails immediately with typed `ManagerUnavailable` and a concise
  actionable failure message rather than attempting elevation or fallback.

The systemd unit fixes `HOME`, `SANAD_HOME`, working directory, user/group for
system scope, `UMask=0077`, cgroup kill behavior, a 90-second stop timeout,
bounded restart policy, journal output, and boot enablement. For system scope the
state paths are the service account's own Home, never the caller's. The OpenRC
service uses `supervise-daemon`, owner-home logs, the same umask and state
variables, boot registration, and restart behavior.

### Stop exit statuses and upgrading an installed unit

The unit keeps `Restart=on-failure` and adds `SuccessExitStatus=130 143`. The
daemon catches `SIGTERM` and `SIGINT` and exits with `128 + signal`, so systemd
observes a normal exit with status `143` or `130` rather than a signal death.
Those are exit codes, not signals: the implicit success set covers exit `0` and
the default signal deaths only, so a requested `systemctl --user stop` would
otherwise leave the unit `failed`, and `sanad service status` would report
`Failed` for a service that stopped exactly as asked, while an operator
`SIGTERM` would be restarted once instead of leaving the Agent stopped. A crash
still exits non-zero and is still restarted.

An installed unit is only rewritten by `sanad service install`. The Client's
update lifecycle re-registers an existing macOS or Linux definition only when
`sanad service definition` reports `matches: false`, and that read-only report
compares the executable, arguments, `SANAD_HOME`, and service instance — not the
rest of the unit body. A unit written by a release that predates
`SuccessExitStatus` therefore keeps the old body after an in-place upgrade; a
fresh installation through `scripts/install.sh` always writes the current unit,
because the installer runs `service install` itself. Run
`sanad service install` once after an in-place upgrade: it replaces the definition
without interrupting a running Agent, because activation only starts a unit that
is not already active. Until then the only difference is the reported state — a
stop leaves the unit `failed` and `sanad service status` shows `Failed` until the
next start, and `systemctl --user reset-failed <unit>` clears that state without
reinstalling.

## Ownership, conflicts, and transactions

A successful installation writes non-secret `service.json` ownership metadata
inside the controlling Sanad Home. Uninstall removes only a definition whose
scope and path match this metadata. An unowned definition is reported but not
deleted.

Unit replacement stages content under Sanad Home. Existing system definitions
are backed up with mode and ownership, and activation must prove both enabled
and running before the backup is removed. Failure restores the previous
configuration and reloads the manager. Symlinked targets are rejected.

Only one user-systemd, system-systemd, or OpenRC definition may own a service
instance. When durable user systemd is unavailable, a known legacy user unit is
stopped, preserved until the replacement is healthy, then removed. Migration
failure rolls back the replacement and restores the legacy unit.

The direct-root dedicated home is recursively assigned to the service account
and restricted to owner access before activation. Agent tools never execute as
root merely because service registration required root privileges.

## Installer health transaction

The Add Device command downloads `install.sh` to an owner-temporary file and
runs it only after curl succeeds; it never relies on pipeline exit semantics.
Pairing authority enters the installer and Agent login through stdin, not the
Agent process argument list.

The installer validates platform, architecture, init support, privilege path,
Sanad Home, manifest trust, artifact size, SHA-256, and macOS publisher before
replacing a binary or preparing pairing. HTTP candidate URLs are accepted only
when the explicit `SANAD_INSTALL_ALLOW_TEST_URL=1` harness flag is set; the
production path remains HTTPS-only and repository-pinned. The Sanad Home it
validates is the one it also selects: an explicit `SANAD_HOME` wins, an explicit
`--run-as-user <account>` picks that account's `~/.sanad`, a root Linux
installation without either uses `/var/lib/sanad-agent`, and only root's own Home
that already carries an installed binary keeps `~root/.sanad`.

For Linux, `service install --expected-version ...` keeps its unit backup open
until authenticated Local Gateway health reports the expected binary version.
Pairing and Portal installs additionally require `cloud_registered=true`, which
is emitted only after the cloud socket receives authoritative
`register_success`. Verification is bounded and keeps the Local Gateway token
inside the verifier process.

The daemon writes that credential during its own startup, which is still in
progress when activation returns, so the bounded window polls the Home's
credential exactly as it polls the HTTP answer: a missing token is a transient
state to wait out, not a final verdict. A window that expires without a token
fails with a message that names the missing credential and the restart that
issues one, instead of reporting a zero-attempt failure that hides how long the
installer waited. Installing afterwards needs a fresh authorization: the failure
path keeps its established credential handling — a token-pairing attempt cancels
the authorization it prepared, and Portal installs keep the credential but leave
no runnable binary — and the installer states that a retry needs a fresh pairing
code or a new Portal approval.

Failure before cloud registration cancels pending pairing and atomically
restores any prior Device Credential. Unit activation/health failure restores
the previous unit, and the shell transaction then restores the prior binary and
running state. A clean failed install removes only the service and pairing state
created by that attempt; it does not remove the wider Sanad Home or workspaces.
