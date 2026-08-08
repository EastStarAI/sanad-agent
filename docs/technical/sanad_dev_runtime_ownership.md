---
title: "sanad-dev Runtime Ownership"
description: "Managed launcher leases, workspace/client ownership, clone isolation, reconciliation, and continuous source handoff."
---

# sanad-dev Runtime Ownership

## Workspace authority

For ordinary `run`, `status`, `stop`, logs, attach, restart, reload, and inspect discovery, the invoking Git workspace is the authority. Its canonical path produces the workspace hash used by daemon health discovery. Inherited `LOCAL_GATEWAY_PORT` and `LOCAL_GATEWAY_URL` values are process context, not ownership evidence, and cannot redirect these commands.

An explicit port remains a diagnostic selector where accepted. Selecting an endpoint explicitly permits inspection; it does not make a foreign endpoint mutable. The requester endpoint remains available only to the separately authorized `switch --runtime current` flow.

## Runtime identity

A discovered runtime group may contain an Agent, one or more Clients, or both. A live Agent is selected by caller workspace hash. A Client remains classifiable while the Agent is paused by its explicit source, reserved gateway port, workspace marker, Home, preferences namespace, launcher id, and runtime nonce:

- **Owned:** source directory, gateway agent port, workspace hash marker, Home, preferences namespace, and required linked-worktree markers form one consistent launch identity.
- **Cross-owned:** the source matches the caller but the gateway belongs to another workspace, or a client attached to the selected agent comes from another source.
- **Unverifiable:** the process launch profile is missing or any identity field is absent or contradictory.

Client consistency alone does not make a group managed. A mutable group also
requires one live launcher lease containing a random launcher id and runtime
nonce, the launcher PID plus process-start/command identity, workspace/source,
Agent port, Home, preferences namespace, and the exact client PID/VM-port set.
Every lease-owned Agent health response and Client launch profile must present
the same launcher id and nonce. The lease's exact managed Client PID/VM
inventory makes Agent-only and Client-only groups verifiable while rejecting
stale records, PID reuse, copied flags, and unrecorded partial managed groups.
Additional manual or foreign Clients are outside that inventory: discovery may
report them, but ordinary commands continue against the exact proven managed
group and never mutate the extras.

The resulting classes are managed, manual, orphaned, cross-owned,
unverifiable, ambiguous, and stopped. Only managed groups accept ordinary
mutation or source handoff. A conflict inside the lease-owned inventory blocks
the complete operation; an unrelated unmanaged process does not. Source-path
equality, `SANAD_DEV_SWITCH_CAPABLE`, a workspace hash, or an explicit port
never grants mutation authority.

Primary IDE clients remain discoverable when they omit gateway, Home, and
preferences defines only under the existing narrow fallback: primary source,
canonical primary endpoint, canonical primary Home, and no explicit conflict.
They are classified as manual, not managed. `sanad-dev takeover` can convert
exactly one fully proven manual Agent/client pair through the daemon's safe
restart boundary. The accepted checkpoint completes as a permanent supervised
shutdown so the previous source supervisor cannot respawn on the claimed port;
incomplete or Agent-tool-origin takeover is refused. A
failed managed launch attempts to restore the previous manual pair.

`sanad-dev run [all|agent|client]` is idempotent for components already active
in one healthy managed group. Missing components are started through a
nonce-bound component request consumed by the existing launcher. `run all`
spawns Agent and Client concurrently and verifies each identity independently.
`stop [all|agent|client]` uses the same control boundary; the helper CLI never
independently kills discovered children. Client targeting considers only
lease-owned Clients and requires an exact managed device match, optionally
disambiguated by VM-service port. An unmanaged Client with the same device does
not make that managed selection ambiguous.
`doctor` is read-only, and `doctor --fix` removes only an invalid/stale record
when its launcher, Agent endpoint, and clients are all absent.
`cleanup-target-orphans` is the only target cleanup operation. It requires a
dead recorded launcher, no target Agent, exact client nonce/profile identity,
and a target Agent port different from the requester/source. IDE-owned,
ambiguous, cross-owned, and source-attached clients are refused.

## Standalone clones

Git identifies both an original checkout and an independent clone as non-linked checkouts, so that fact alone cannot grant primary ownership. A non-linked checkout may use the normal primary Home and canonical endpoint while there is no contradictory active owner. If the canonical endpoint reports another workspace hash, or a foreign-source client already uses the same primary Home, `run` fails closed and asks for an explicit absolute `--home`.

An absolute Home turns the independent clone into an isolated runtime:

- the Home is the supplied absolute directory;
- preferences use a deterministic Home-derived prefix;
- the agent starts from a workspace-hashed candidate in the development range rather than the canonical primary port;
- the VM-service port remains workspace-hashed.

This conflict check is read-only, including in dry-run. A cross-owned client is reported as such, with stop explicitly refused; it is never described as a cleanup candidate.

## Continuous source handoff

`switch --runtime current` requires the complete live launcher lease and embeds
its launcher id and nonce in the versioned handoff transaction. The launcher
retains that identity, Home, Agent port, preferences namespace, devices, and VM
ports while replacing source roots and workspace markers. A manifest with an
unsupported version or invalid shape remains fail-closed and is not mutated by
the launcher. Polling reports an unchanged invalid on-disk revision only once;
a replaced invalid revision can produce one new diagnostic, and a valid or
absent manifest resets that suppression.

For an Agent-origin command, the CLI emits a requester-bound deferred-result
descriptor instead of treating `Switch accepted` as completion. The descriptor
is persisted with the executing tool before the daemon drain. Controlled
restart recognizes only the exact durable requester descriptor. Startup
recovery then reads the port-scoped transaction and persists one terminal
result into the original tool call:

- `complete` means the target group is healthy and the session resumed there;
- `rolled_back` means target startup failed, the previous group is healthy, and
  the same session resumed there;
- `failed` means replacement did not begin or the safe drain was rejected;
- `recovery_failed` means neither target nor previous group was verified.

The switch mutation is never replayed. Checkpoint restoration returns every
requester-bound deferred tool-call id to the runner before trimming history. The
runner preserves that call's complete durable assistant batch, resolves its
launcher manifest through the tool coordinator, and only then continues the
model loop. This prevents a second model-generated `switch` while the target
Agent is healthy but its Clients are still starting. A crash after terminal
persistence reads the already completed tool result. `status` keeps the outcome
as `Last source switch` diagnostics, but the requester does not need a second
command.

Before replacement starts, the launcher waits for every previous managed Client
process and retained VM-service endpoint to disappear. Target or rollback
readiness then requires exactly one discovered Client per reserved VM port whose
workspace source marker, launcher id, and runtime nonce match the expected
group. A stale previous-source Client can neither satisfy readiness nor
supply a PID to the rewritten launcher lease; terminal `complete` or
`rolled_back` is persisted only after this exact identity set is available.

## Resumable development shutdown

The local daemon distinguishes a resumable development shutdown from terminal
cancellation. `POST /shutdown?mode=pause` enters the same global admission
drain used by controlled restart and waits for every active session to reach a
recognized durable checkpoint. A timeout or unsafe blocker rejects the request,
cancels the drain, and leaves the daemon running. After an accepted response is
flushed, the daemon exits its source supervisor permanently without invoking
session-wide Stop, so startup recovery can reclaim checkpoint-safe work and the
existing FIFO queue.

`POST /shutdown?mode=cancel` is the destructive counterpart: it requests
session-wide bounded cancellation before permanent exit. The two modes must not
be inferred from process signals. Component-aware `sanad-dev stop` commands
select the mode explicitly; force is meaningful only for a target that owns the
Agent and never changes Client-only shutdown semantics.

## Bootstrap and source profile

Bootstrap is owned by the platform wrappers because Dart cannot run before FVM
and the pinned Flutter SDK exist. POSIX and PowerShell expose the same layered
command contract. No arguments render static help without mutation. `install`
owns verified FVM, pinned Flutter, and the checkout-owned user shim, then stops.
`setup` ensures install, resolves the Release Contract followed by Agent and
Client packages, then stops. `run` ensures only missing or stale install/setup
stages before entering the runtime CLI. Other runtime commands never bootstrap
implicitly and fail with the exact prerequisite command when the Dart CLI is not
ready.

Missing FVM is installed from pinned official release archives after
per-platform SHA-256 verification; detecting ready FVM, Flutter, shim, or package
state is intentionally silent. Work-performing stages stream the child process's
stdout/stderr without buffering, then report elapsed duration and success or
failure. The idempotent setup stamp binds `.fvmrc` plus the Release Contract,
Agent, and Client lockfiles and package configs. Failure is terminal for every
dependent stage and runtime launch. Explicit install/setup refuse silent shim
replacement; run accepts an existing functional dispatcher so linked worktrees
do not contend for the user command.

The wrapper resolves the invoking Git worktree before entering Dart. If a
user-scoped shim or wrapper from another checkout receives the command, it
redispatches once to the invoking worktree's wrapper. This keeps both bootstrap
and runtime CLI source on one checkout instead of combining a foreign wrapper
with the caller's Dart files.

The Runtime CLI remains `scripts/sanad_dev.dart`. Its client profile default is
`client/config/prod.json`, with local and Cloud enabled for every checkout type.
The development profile and endpoint overrides are explicit internal integration
choices; `--no-cloud` is the explicit hosted-disable boundary. Automated tests
inject fakes and never connect to Production.

## Managed component journals

The launcher owns one bounded journal stream for the Agent and one for each
Client VM-service port. Capture begins immediately after `Process.start`, before
health or VM readiness, and includes both process stdout and stderr. Records keep
source, timestamp, sequence, and raw encoded bytes so ANSI and partial text are
not changed by storage. Readers render original bytes without exposing metadata.
Generation markers preserve continuity across Agent restart and source handoff.

Journals live below the selected runtime Home and correlation identity consists
of launcher id, runtime nonce, component, Agent port, and optional Client VM
port. They are diagnostics only: lease/process/health/VM evidence remains the
sole liveness and mutation authority. Four 2 MiB segments are retained per
component, stale files are removed after 14 days, POSIX permissions are
`0700/0600`, and Windows ACL inheritance is replaced by an owner-only grant.
Recognized credential-shaped output is redacted and each stored record is
bounded.

Managed `logs` takes a history snapshot with exact segment byte offsets, applies
`-n` to rendered lines, then follows only bytes after that cursor. Rotation uses
monotonic segments rather than rewriting the active file. Client watchers can
open before VM readiness using Home, Agent port, and reserved VM port. Ordinary
Client log reads derive the journal Home and Agent port from the selected live
Client launch profile rather than assuming the caller's candidate runtime port. A manual
runtime has no complete process journal; its Agent HTTP and Client VM logger
fallbacks state that boot/build/process output may be unavailable.

When `run client` joins an Agent-only runtime, its interactive surface begins
with the last 50 retained lines and then follows new output. Explicit `logs`
continues to honor the caller's `-n` choice or full retained history.

## Terminal ownership

For `run all`, Agent output remains in the launcher terminal and every Client
gets an independent journal terminal. `run client` never opens a second terminal;
its output and controls stay in the invoking terminal even when an existing
Agent launcher creates the Client. Starting another Client as part of an
all-component request opens one additional Client terminal; closing a Client
closes only that surface. Client terminals route Flutter's complete interactive
set through the owning launcher: `r` reloads, `R` restarts, `h` lists help, `d`
detaches, `c` clears, and `q` quits the Client. Agent terminals route `r`/`R` to
the supervised daemon restart endpoint and `s`/`q` to the resumable managed
Agent stop operation; stopping the Agent does not stop sibling Clients. These
terminals never acquire process ownership: the launcher remains the sole
stdin/process owner.

An automatically opened Client terminal renders only the latest 50 retained
lines before following live output. Its pre-identity follow grace matches the
six-minute component-control window, so it remains attached throughout the
five-minute Client cold-build decision. Explicit `logs` invocations retain the
caller's own history selection.

Component control waits six minutes, longer than both bounded cold-start
windows. A slow Agent or Client start therefore cannot time out the requesting
command or terminate an already-running sibling. Completed control files are
published atomically with owner-only permissions; on POSIX the restricted
temporary inode's mode survives rename, so an immediate consumer delete cannot
race a redundant post-publication permission change.

Every managed Client launch, source switch, rollback, and manual restoration
uses one bounded five-minute readiness window. This accommodates slow desktop
cold builds without treating dependency resolution or native compilation that
exceeds 90 seconds as a failed Client identity probe.

Terminal capability is platform-adapted: macOS Terminal via AppleScript, a
detected supported Linux terminal, and Windows Terminal or PowerShell with
platform-safe quoting. Non-interactive/headless execution and adapter failure do
not change process ownership or launch success and emit a bounded copyable logs
command instead.

## Privacy

Absolute paths remain local process-discovery and CLI presentation data. Agent
health exposes workspace hash, abstract state, and the development launcher
id/nonce over loopback. The id and nonce are correlation evidence rather than
credentials and grant no authority without the complete local lease and client
agreement. No Home or source path crosses the health protocol.

Agent discovery and lifecycle calls are authenticated with the credential read
from the candidate runtime Home. It is added only to Agent HTTP and WebSocket
headers; VM-service transports remain separate. The credential is excluded from
leases, journals, URLs, queries, process arguments, and rendered diagnostics.
