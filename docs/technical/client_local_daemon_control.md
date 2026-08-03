---
title: "Client Local Daemon Control"
description: "Architecture for source and standalone daemon lifecycle control from the Flutter desktop client."
---

# Client Local Daemon Control

## Abstraction

`LocalDaemonController` is the platform-neutral boundary used by device state to
query health and request daemon start, stop, restart, or update behavior. UI and
cubits depend on this abstraction and do not branch on packaging mode.

## Standalone Runtime

`StandaloneDaemonController` manages the installed Sanad executable and the
operating-system background service. The executable normally lives under the
Sanad home binary directory, while launchd, systemd, or the Windows service
adapter owns process persistence. Lifecycle actions target the registered
service rather than an arbitrary process discovered by the UI.

When the daemon is installed, update requests are delegated to its local
`/update` endpoint so `AgentUpdateService` remains the only replacement owner.
The client uses the shared verified bootstrap installer only when no standalone
daemon executable exists yet. Later updates never use that bootstrap path.

## Source Runtime

`SourceDaemonController` represents a daemon launched externally from source by
a developer or the worktree runtime. It does not auto-start by default and does
not force-terminate the developer's shell process. Stop and restart requests
prefer the daemon's controlled lifecycle endpoint so runtime checkpoints and
supervisor semantics are preserved.

An update request against a source runtime returns `source_managed`. It never
pulls Git, invokes FVM, or rewrites the developer checkout.

## Endpoint Resolution

Health, lifecycle, update, socket, and voice endpoints derive from
`AppConfig.localGatewayUrl`. The controller architecture cannot assume the
production default port because linked worktrees receive isolated daemon and VM
service ports.

Desktop health, lifecycle, update, socket, and voice requests authenticate with
the Local Gateway credential stored under the active Sanad Home. The client
loads it at request time and transmits it only as a header, so daemon and client
restarts do not require a credential in launch arguments or preferences.
Flutter Web and mobile are remote-only and never attempt this lookup or local
connection.

## Worktree Client Restart and Reload

`sanad-dev` discovers the live Flutter VM service and the matching `flutter run`
process as one client instance. Process arguments come from lossless
platform-native sources: NUL-delimited procfs arguments on Linux,
`kern.procargs2` on macOS, and `CommandLineToArgvW` over the native Windows
command line. Formatted `ps` output is never tokenized. Restart and reload reuse
the resulting exact compile-time launch profile, including config-file
arguments, local gateway URL, cloud mode, Sanad Home, SharedPreferences
namespace, worktree marker, branch, target, and device. This preserves argument
boundaries when repository, configuration, or home paths contain spaces.
Incomplete process discovery fails closed; it never injects `config/local.json`
or rebuilds the client from default compile-time values.

Before attach, linked-worktree identity must match the current Git worktree and
the local gateway port must match the active agent carrying the same workspace
hash. The launch profile's SharedPreferences prefix must exactly equal the
namespace derived from its canonical Sanad Home. The empty namespace is valid
only for the canonical primary/user home; linked defaults and absolute custom
homes require their deterministic home-derived namespace. This preserves valid
`--home user` and absolute `--home` launches across later CLI invocations,
without replacing their profile with a newly inferred default. Missing launch
metadata or any conflicting identity aborts without touching the running
client. Primary and linked client
directories are resolved from the canonical `.agent/worktrees/` boundary,
without deriving a path from a Flutter target. Attach executes through FVM from
the matched client directory. A Flutter attach failure or an attach session
that ends without observing the requested reload/restart completion produces a
nonzero CLI exit.

## Configuration and State

The active `SANAD_HOME` owns machine identity, auth, providers, `state.db`,
memories, and runtime dumps. A linked `sanad-dev` runtime receives one
worktree-scoped home plus a deterministic SharedPreferences prefix derived from
that home, isolating client caches and preferences despite a shared bundle id.
The primary checkout, packaged application, and explicit `user` selection retain
the ordinary home and default preference namespace. Absolute custom homes receive
their own namespace. External tests may still use `SANAD_STATE_HOME`, but
`sanad-dev` does not inject it.
