---
title: "Linux Agent Service Lifecycle"
description: "Technical contract for Linux service selection, ownership, installation transactions, and lifecycle reporting."
---

# Linux Agent Service Lifecycle

## Scope

This document defines the Agent-owned Linux service registration implemented by
`agent/lib/core/setup/`. Installer transaction and cloud-health behavior remain
owned by Task 81 G4 and are not claimed here.

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

Selection is capability-based and ordered:

1. A user systemd service is selected only when the user bus exists, linger is
   enabled and reverified, and `systemctl --user show-environment` succeeds with
   explicit `HOME`, `XDG_RUNTIME_DIR`, and bus address.
2. A system systemd unit is selected when systemd is present but the user
   manager is not durable. A non-root invocation uses sudo only for system
   registration while the unit runs as the invoking user. Root invoked through
   sudo resolves the validated original account. Direct root invocation creates
   the fixed unprivileged `sanad-agent` account and state home.
3. OpenRC is selected only when systemd is absent and native OpenRC commands are
   available. Unsupported init systems return `ManagerUnavailable` before a
   service definition is installed.

The systemd unit fixes `HOME`, `SANAD_HOME`, working directory, user/group for
system scope, `UMask=0077`, cgroup kill behavior, a 90-second stop timeout,
bounded restart policy, journal output, and boot enablement. The OpenRC service
uses `supervise-daemon`, owner-home logs, the same umask and state variables,
boot registration, and restart behavior.

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
production path remains HTTPS-only and repository-pinned.

For Linux, `service install --expected-version ...` keeps its unit backup open
until authenticated Local Gateway health reports the expected binary version.
Pairing and Portal installs additionally require `cloud_registered=true`, which
is emitted only after the cloud socket receives authoritative
`register_success`. Verification is bounded and keeps the Local Gateway token
inside the verifier process.

Failure before cloud registration cancels pending pairing and atomically
restores any prior Device Credential. Unit activation/health failure restores
the previous unit, and the shell transaction then restores the prior binary and
running state. A clean failed install removes only the service and pairing state
created by that attempt; it does not remove the wider Sanad Home or workspaces.
