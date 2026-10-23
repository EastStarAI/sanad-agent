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

When the daemon is running, update requests are delegated to its local
`/update` endpoint so `AgentUpdateService` remains the replacement owner.

When the daemon is stopped, `StandaloneDaemonController.updateDaemon` owns the
whole lifecycle (`ownsStoppedAgentLifecycle` is true), so the coordinator hands
it the stopped Agent instead of starting the service first:

1. Read the installed version with `sanad --version`. Only the dedicated
   `Version:` line is accepted, with any prerelease suffix kept; an OS or
   kernel version elsewhere in the output is never used.
2. Check service compatibility with `sanad help service install` and require
   every option in the platform's service install arguments (today only
   `--user-scope` on Linux) as an exact flag.
3. Reuse a compatible executable at the target version. Replace an absent,
   older, unparseable, or incompatible one through the verified bootstrap
   installer before any registration, so an old binary is never invoked with
   an option it lacks. Never replace a newer executable. Start it when
   compatible; once healthy it is `newerAgentInUse` (`isSuccess` true, with
   `agentVersion`). An incompatible or non-starting newer executable is
   `downgradeRejected`.
4. Register the service when needed, start it, and wait for target-version
   health. After a verified replacement on macOS or Linux, an existing
   registration is reused unless the new executable's read-only
   `sanad service definition` report says the installed plist or systemd user
   unit differs from the one it would generate (executable, arguments,
   `SANAD_HOME`, and the plist's `SANAD_SERVICE_INSTANCE`); then the service is
   re-registered exactly once. An unknown report reuses the registration. That
   report compares definitions, not complete bodies: a change to any other unit
   or plist field, such as the systemd unit's `SuccessExitStatus`, is not
   detected and reaches an existing installation only through a later
   `sanad service install`.
   Windows refreshes its Scheduled Task on every registration. A failure after replacing an existing executable restores the
   previous copy (see [Release and Update Architecture](update_architecture.md));
   success removes the `.rollback` copy.

The coordinator records the last result as `localAgentLifecycle` and emits a
change. `LocalAgentLifecycleNotice` renders the localized `newerAgentInUseNotice`
(en/ar) for the local device in Settings, and **Run Sanad Locally**
(`InstallationTerminalView`) logs the same notice as `[INFO]` and completes.

### Executable probes

Probes are read-only, bounded, and Home-pinned. The capability probe is the
`help <command>` form because it is read-only on every release; v1.0.0–v1.0.4
ignore `service install --help` and perform a real installation. Each probe
closes stdin, runs with `SANAD_HOME` set to the managed Home, and is killed
after `StandaloneDaemonController.defaultExecutableProbeTimeout` (20 seconds);
a timeout counts as an unknown version or an incompatible executable.

Every agent child process the controller runs (probes and `service install`,
`start`, and `stop`) receives `SANAD_HOME` for the managed Home and, when
configured, `SANAD_SERVICE_INSTANCE`. The agent resolves its Home only from
that variable (else `~/.sanad`), so a Client built for an isolated Home can
never register, start, or stop the default service. Agents from this release
answer `--version` and `help …` before preparing any Home, so a probe writes
nothing; older Agents may still initialize the managed Home, never another one.
`registerService` repeats the capability check and refuses to run
`service install` with options the executable does not support.

### Source runtimes and concurrency

`SourceDaemonController` keeps `ownsStoppedAgentLifecycle` false: an explicit
**Run Sanad Locally** starts the developer's source daemon and only then asks
for an update, which returns `source_managed`. `checkAndStartLocalDaemon` is
single-flight; concurrent callers share one attempt, and a forced caller that
joined a failed unforced attempt retries once with force.

### Service Registration and Error Diagnostics

During bootstrap, the Client installs and registers the background daemon
service. On Linux, `StandaloneDaemonController` explicitly passes `--user-scope`
to `sanad service install`, guaranteeing unprivileged registration in the
user's systemd session without attempting `sudo`, `pkexec`, or system fallback.
The explicit path requires the host `/run/user/<uid>/bus` socket (and supplies
the derived environment) rather than accepting `DBUS_SESSION_BUS_ADDRESS`
independently. On macOS and Windows, standard `sanad service install` is
invoked without extra flags.

When service registration fails (exiting with a nonzero code), the controller
sanitizes the process output before surfacing it:
- ANSI escape sequences and non-printable control characters are stripped.
- The most concise, actionable diagnostic line is extracted from stderr,
  stdout, or exit messages, and bounded to at most 120 characters.
- Unsuitable content (such as stack traces, JSON objects, internal shell command
  payloads, and tokens/credentials) is rejected.
- When a valid diagnostic is extracted, it is appended to the user-visible
  `AgentLifecycleResult.message` (for example,
  `The agent was downloaded but its background service could not be registered: The systemd user service manager is unavailable.`).
- If registration output is empty or unsuitable, the controller cleanly falls
  back to the generic message (`The agent was downloaded but its background service could not be registered.`).

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

On Desktop, an authenticated ready Local Gateway is sufficient to complete app
bootstrap and enter Home regardless of cloud-login state. If startup temporarily
reaches Login or Onboarding before the local socket becomes ready, the gateway
state refresh redirects to Home automatically; **Run Local** is reserved for
install/start/repair when no ready local connection exists.

The active `SANAD_HOME` owns machine identity, auth, providers, `state.db`,
memories, and runtime dumps. A linked `sanad-dev` runtime receives one
worktree-scoped home plus a deterministic SharedPreferences prefix derived from
that home, isolating client caches and preferences despite a shared bundle id.
The primary checkout, packaged application, and explicit `user` selection retain
the ordinary home and default preference namespace. Absolute custom homes receive
their own namespace. Client identity, settings, lifecycle, HTTP, and WebSocket
credential readers resolve the same active Home in the order explicit dependency
override, compile-time `SANAD_HOME`, runtime `SANAD_HOME`, then the ordinary user
home. This keeps packaged isolated lifecycle harnesses authenticated without
baking a machine-specific path into the candidate. External tests may still use
`SANAD_STATE_HOME`, but `sanad-dev` does not inject it.
