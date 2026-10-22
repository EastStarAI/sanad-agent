---
title: "sanad-dev Runtime Ownership"
description: "Managed launcher leases, workspace/client ownership, clone isolation, continuous source handoff, and the reset, apply, refresh, `cli`, status, and doctor runtime tooling."
---

# sanad-dev Runtime Ownership

## Package module ownership

`scripts/sanad_dev/lib/sanad_dev_cli.dart` is the composition root for the
standalone Pure-Dart CLI. Its implementation is organized under `lib/src/` by
responsibility:

- `cli/` parses typed invocations, renders mutation-free help, resolves the
  selected runtime, and dispatches commands;
- `discovery/` inspects OS processes, correlates Flutter/DDS instances, probes
  authenticated Agents, infers the active Home, and performs exact selection;
- `runtime/ownership/` projects process state and validates managed launcher
  ownership;
- `runtime/lifecycle/` owns run, readiness, status, reset with Home fixtures,
  apply, refresh, the compiled-CLI runner, the restart build guard, component
  stop/control, doctor, orphan cleanup, takeover, and bounded wait orchestration;
- `runtime/switch/` owns source-handoff admission, process waits, transaction
  control, target launch, rollback, and terminal result persistence;
- `developer/` owns bounded journals, Client reload/restart/DevTools actions,
  Agent restart/log actions, and UI-driver forwarding;
- `infrastructure/` owns secure files, credentials, runtime context, launch
  profiles, journals, startup records, endpoint configuration, terminal adapters,
  the per-SHA compiled CLI cache, Home fixtures, the foreign-worktree build probe,
  and scheduled refresh plans.

Files in `lib/src/` depend directly on the narrow owning implementation rather
than importing through root compatibility facades. The `lib/` root contains
only the composition root and a thin `runtime_context.dart` forwarder retained
for the tracked Client interactive inspector consumer. Package-owned tests
import `lib/src/` modules directly; an internal test is not evidence that a new
public root facade is required.

Tests mirror these domains below `scripts/sanad_dev/test/`, with reusable fakes
and builders under `test/support/`. A deterministic size guard keeps handwritten
production and ordinary test files at or below 700 lines and keeps the CLI
dispatcher at or below 250 lines.

## Workspace authority

For ordinary `run`, `status`, `stop`, logs, attach, restart, reload, and inspect discovery, the invoking Git workspace is the authority. Its canonical path produces the workspace hash used by daemon health discovery. Inherited `LOCAL_GATEWAY_PORT` and `LOCAL_GATEWAY_URL` values are process context, not ownership evidence, and cannot redirect these commands.

`run --home <absolute-path>` records the resolved Home in the owner-only workspace startup locator. Later commands from that workspace can omit `--home`: discovery validates the locator against its Home-resident startup record and uses the resolved Home only as a Local Gateway credential candidate. A supplied `--home` remains authoritative and restricts credential discovery to its resolved Home. `run` without a selector still chooses the normal checkout/worktree default rather than silently reusing the previous custom Home. Locator state never establishes liveness or mutation authority; all existing launcher lease, process identity, Agent health, Client profile, launcher-id, and runtime-nonce checks still apply.

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
group and never mutate the extras. Client discovery recognizes both the native
`development-service` entry point and Flutter Web's direct DDS snapshot when
its exact VM URI and bind-port arguments map to a matching Flutter runner.
Flutter Web may generate an external VM authentication code different from the
upstream DDS URI; the managed Client journal can recover that code only for
diagnostic attachment after process/profile correlation. Journal text never
establishes liveness or ownership. When `SANAD_DEV_WEB_PORT` is present,
`sanad-dev` validates it as a TCP port and adds `--web-port` only to Chrome;
the owning launcher reapplies it when starting an additional Chrome Client. This
allows a persistent browser profile to retain origin-scoped Web Storage across
stops without leaking the setting into native platform launches. `sanad-dev ui`
narrows the exact owned set
again to launch profiles targeting `lib/driver_main.dart`; a regular managed
Client can neither replace nor make a worktree's driver selection ambiguous.

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
On Windows, environment composition refreshes the Machine+User system PATH
through the shared cached resolver before Agent or Client spawn. This prevents
a stale invoking terminal from hiding newly installed OS tools, normalizes
`Path`/`PATH` casing to one child entry, and falls back to the inherited value
without blocking launch when registry resolution fails. POSIX environments are
unchanged.
`stop [all|agent|client]` uses the same control boundary; the helper CLI never
independently kills discovered children. Client targeting considers only
lease-owned Clients and requires an exact managed device match, optionally
disambiguated by VM-service port. An unmanaged Client with the same device does
not make that managed selection ambiguous.
`doctor` is read-only and prints one concrete next command/action for each
classification. `doctor --fix` removes an invalid/stale record directly only
when its launcher, Agent endpoint, and Clients are all absent. Its only
stale-live recovery is an exact Agent-only record: the launcher is dead, the
record and discovery contain no Clients, and Agent port, workspace, source,
Home, launcher id, and runtime nonce all match. From a human-owned terminal it
requests an authenticated permanent Agent restart, waits for endpoint exit,
rediscovers Agents and Clients, rechecks the launcher, and deletes the record
only after every matching live surface is absent. Agent-tool origin, identity
mismatch, rejection, timeout, or post-drain evidence preserves the lease.
`cleanup-target-orphans` remains the only target Client cleanup operation. It requires a
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
ports while replacing source roots and workspace markers. The target Agent is
spawned with the target workspace hash, worktree name, and branch already in its
environment before health readiness is evaluated. The transaction keeps an exact
snapshot of the previous Agent environment and uses that snapshot for rollback,
so failed target startup cannot leak target markers into the restored source.
The CLI reports that a runtime already uses the target only when the Agent
workspace hash and every
managed Client source path agree with that target; partial agreement is an
inconsistent managed source and fails closed with a diagnostic. A manifest with an
unsupported version or invalid shape remains fail-closed and is not mutated by
the launcher. Polling reports an unchanged invalid on-disk revision only once;
a replaced invalid revision can produce one new diagnostic, and a valid or
absent manifest resets that suppression. Before submitting a new handoff, the
CLI compares any active-status manifest with the validated live launcher id and
runtime nonce. A matching owner remains active and blocks the new request. A
mismatched owner proves the record belongs to a previous launcher, so the CLI
atomically terminalizes it as `failed` without signaling any process and then
continues normal switch preflight. `sanad-dev doctor --fix` applies the same
identity check to repair an orphaned active-status handoff independently of a
new switch request.

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
`setup` ensures tooling, resolves the Release Contract, standalone CLI, Agent,
and Client packages, then compiles the package-owned runtime CLI through FVM
into a checkout-local native artifact before stopping. `setup`, `run`, and
`switch` preserve a functional user shim owned by another checkout; changing
shim ownership remains an explicit `install --force` action. `run` ensures only
missing or stale install/setup/runtime-artifact stages before entering that CLI.
`switch` performs the same idempotent target preparation before submitting its
handoff transaction. Preparation failure occurs before runtime mutation, so the
source group remains unchanged. Other runtime commands never bootstrap implicitly and
fail with the exact setup recovery command when the prepared CLI is missing or
stale.

Missing FVM is installed from pinned official release archives after
per-platform SHA-256 verification; detecting ready FVM, Flutter, shim, or package
state is intentionally silent. Work-performing stages stream the child process's
stdout/stderr without buffering, then report elapsed duration and success or
failure. The idempotent dependency stamp binds `.fvmrc` plus all package
lockfiles and package configs. A separate runtime fingerprint binds the
standalone CLI's `lib/`, `pubspec.yaml`, and lockfile to a fingerprint-named
native artifact. A changed source builds beside any still-running artifact.
Windows cleanup removes only stale artifacts that are no longer locked; POSIX
retains prior cache artifacts because an active launcher may need its executable
path for a later child spawn. Setup reuses an existing artifact whose filename
matches the current fingerprint, including after a stamp rollback, so Windows
never tries to overwrite that still-running executable. This lets warm runtime
commands bypass repeated FVM SDK resolution while source changes remain
fail-closed. Failure is terminal for every dependent stage and
runtime launch. Explicit install/setup refuse silent shim replacement; run
accepts an existing functional dispatcher so linked worktrees do not contend
for the user command.

The wrapper resolves the invoking Git worktree before entering the prepared
runtime CLI. If a user-scoped shim or wrapper from another checkout receives the
command, it redispatches once to the invoking worktree's wrapper. This keeps both
bootstrap and runtime CLI source on one checkout instead of combining a foreign
wrapper with the caller's artifact.

The Runtime CLI source is `scripts/sanad_dev/lib/sanad_dev_cli.dart`;
`scripts/sanad_dev.dart` remains a compatibility forwarder only. Its client profile default is
`client/config/prod.json`, with local and Cloud enabled for every checkout type.
The development profile and endpoint overrides are explicit internal integration
choices; `--no-cloud` is the explicit hosted-disable boundary. Automated tests
inject fakes and never connect to Production.

## Runtime tooling commands

`reset`, `apply`, `refresh`, `cli`, `status`, and `doctor` are the worktree-local
tooling surface for live rounds. Every one of them is scoped to the invoking
worktree's own runtime and Test Home; none of them can reach another worktree's
runtime or the primary user Home. `status` and `doctor` are strictly read-only,
and `reset` is the only command that destroys runtime state.

### Compiled CLI cache (`sanad-dev cli`)

`fvm dart run bin/sanad_agent.dart` costs 6.5 s per call on the reference host
(SDK resolution plus kernel compile). `sanad-dev` therefore keeps one native
artifact per component and per runtime commit:

| Component | Entry point | Build command | Cached executable |
| --- | --- | --- | --- |
| Agent | `agent/bin/sanad_agent.dart` | `fvm dart compile exe bin/sanad_agent.dart -o …` | `.sanad-dev/bin/<sha>/agent[.exe]` |
| Client | `client/bin/sanad_client.dart` | `fvm dart build cli -t bin/sanad_client.dart -o …` | `.sanad-dev/bin/<sha>/client-bundle/bin/sanad_client[.exe]` |

The Client CLI cannot use `dart compile exe`: the Client package carries native
build hooks (`cnativeapi`, `objective_c`), so `dart build cli` is used and its
bundle keeps the dynamic libraries beside the executable. The Agent compile
receives `-DSANAD_AGENT_VERSION=<agent/pubspec.yaml version>` so a compiled
binary reports the same version as the `fvm dart run` path.

`<sha>` is the first 12 characters of the runtime source `HEAD` (`nogit` outside
a Git checkout). Beside each artifact, `<component>.stamp` holds a SHA-256 over
that component's `pubspec.yaml`, `pubspec.lock`, every file under `lib/`, `bin/`,
and `hook/`, every transitive `path:` dependency package root (breadth-first over
each path dependency's own pubspec), and the Flutter pin: `.fvmrc` when present,
otherwise the installed `fvm dart --version`. The artifact is reused only when
the stamp matches, so a dirty tree, a changed shared package, a changed native
build hook, or a new Flutter pin rebuilds in place; nothing is ever reused
across commits.

Two callers can race, and an interrupted build must not leave a usable artifact:

- `<component>.build.lock` is held exclusively for a whole build. The lock
  combines an OS file lock with an in-process mutex, because a POSIX record lock
  cannot serialize two callers inside one process. A contending caller waits up
  to 15 minutes, then re-checks the stamp instead of rebuilding.
- Builds are staged (`agent.building`, `.client-bundle-building`) inside the
  commit directory and published with a single rename, so a failed or
  interrupted build leaves neither artifact nor stamp.
- Every publish prunes older commit directories beyond the three most recent and
  never removes the directory it just published.
- `cli path` and `cli <component>` take the shared half of the lock only while
  the artifact is started, so a reader never observes a half-published bundle and
  a long child run never blocks a rebuild. A rebuild publishes into a new
  `<sha>/` directory and never rewrites the inode a running child already exec'd,
  so holding the shared lock for the child's whole lifetime bought nothing and
  blocked every rebuild for up to 15 minutes.

| Command | Effect |
| --- | --- |
| `sanad-dev cli path agent\|client` | Ensures the artifact and prints its path with the cache key and `built in <duration>` or `reused`. |
| `sanad-dev cli agent\|client -- <args>` | Ensures the artifact and runs it with inherited stdio, then prints `call <duration>` on stderr and returns the child exit status. |

Measured on the reference macOS host (Dart 3.13, warm pub cache): Agent build
14.4 s cold, `cli path agent` 0.27 s warm, `sanad-dev cli agent -- --version`
355 ms; Client bundle 47 s with a cold hook build and 2.1 s warm,
`sanad-dev cli client -- --version` 239 ms. `.sanad-dev/` is gitignored.

### `sanad-dev reset` and Home fixtures

`sanad-dev reset [--fixture <name>] [--save-fixture <name>] [--include-mcp-config] [--keep-data]`
is the single command that replaces the hand-written stop/restore/run sequences:

1. Refuse a Home this worktree does not own (see below) before any mutation.
2. Stop this worktree's Agent and Client through the normal managed component
   boundary, then prove the Agent port, the reserved VM-service port, and every
   managed Client endpoint are free (TCP connect plus client discovery).
3. `--save-fixture <name>` snapshots the Home's databases and configuration into
   `<worktree>/.sanad-dev/fixtures/<name>/` through a staging directory.
4. Restore `--fixture <name>` when requested; otherwise keep the data.
5. Launch the matched runtime with `run --driver` in the background, wait for the
   managed state, and print exactly one summary line:
   `reset: worktree=… agent=… vm=… sha=… state=… home=… fixture=…`.

`reset` always launches a driver-enabled runtime, because that is its purpose.
`--fixture` and `--keep-data` are mutually exclusive; `--keep-data` is otherwise
the explicit default, since a `reset` without a fixture restarts the pair and
leaves the Home data alone. `--dry-run` prints the plan and touches nothing.

Home scope is deliberately narrower than every other command. Only a Home equal
to, or below, `<user home>/.sanad/dev/homes/<worktree id>` is accepted. The
primary user Home `~/.sanad` is always refused, and shared homes such as
`~/.sanad-test*` or another worktree's Test Home are refused as foreign.

A fixture captures an explicit allowlist and nothing else:

| Included | Excluded (never copied, never replaced) |
| --- | --- |
| `state.db`, `state.db-wal`, `state.db-shm` | `.env`, `.env.*` (provider keys) |
| `config.yaml` | `.local_token`, `.local_token.lock` (local gateway credential) |
| `models_dev_cache.json` | `provider_secrets.json`, `provider_auth.json`, `mcp_secrets.json`, `auth.json` |
| `mcp_config.json`, only with `--include-mcp-config` | `agent_credentials.json`, `agent_credential_backend.json` |
| `skills/` (recursive) | OS keychain/SecretVault material |
| `memories/` (recursive) | any file whose name contains `token`, `secret`, `credential`, `vault`, `keyring`, `password`, `apikey` |
| `workspaces/` (recursive) | any file whose name begins with `id_` or ends with `.key`, `.pem`, `.p12`, `.p8`, `.netrc` |
| | any path under a `logs/` or `request_dumps/` directory |
| | `dev/` (leases, journals, control and switch records), `media/`, `attachments/`, `sessions/`, `bin/` |

`mcp_config.json` is opt-in because it can carry provider or tool arguments; the
CLI prints a warning that the saved fixture inherits whatever that file contains.
Capture is by allowlist and every path is filtered again by the exclusion list,
so a secret placed inside `memories/` or `skills/` is still skipped. Symbolic
links are never followed. The fixture manifest (`fixture.json`, schema version 2)
records the creation time, source Home, whether MCP configuration was included,
and the size plus SHA-256 of every file.

Every captured file and directory is created owner-only (`0700` directories,
`0600` files) both in the fixture and when restoring, so a fixture never widens
the permissions of the Home.

Restore validates before it writes anything. A manifest entry is rejected unless
its recorded path is relative, contains no `.` or `..` segment, is not Windows
drive-qualified or absolute, still passes the exclusion list, and resolves inside
the Home with no symbolic link in any intermediate segment. The Home target is
validated before the fixture bytes are read, so a Home reached through a symlinked
parent refuses with a symbolic-link error instead of a checksum error.

Restore then stages every captured file into a per-Home sibling directory,
`<home parent>/.sanad-dev-reset-staging-<home label>-<home digest>/` (never inside
the Home, so it can be found again). The staging directory is keyed by the Home's
canonical path because every worktree Test Home shares the `homes/` parent: a
fixed name let crash recovery in one worktree move another Home's backed-up
`state.db` into its own Home and let two parallel resets delete each other's
in-flight backups. Recovery reads and deletes only its own staging directory, and
a `staging-home` marker inside it refuses recovery when the recorded Home differs
from the Home being restored.

The swap removes captured files the fixture does not contain and moves each
top-level group — the `state.db` family travels as one group, matched
case-insensitively so a case-insensitive disk keeps the database and its
WAL/SHM sidecars together — into place with same-filesystem renames. A group that
fails mid-swap is restored from the retained original, and a crashed run is
rolled back on the next attempt from the same staging directory.

When the rollback itself fails, the staging directory is kept rather than deleted,
and the message names its path together with what to move back by hand, so a
failure never silently discards the only copy of a Home file. The success message
`The Home was rolled back to its previous state.` is therefore always true, and a
failed rollback never prints it. No destination file is ever half-written, and no
excluded path is read, replaced, or deleted — the gateway credential, `.env`,
journals, logs, media, and runtime leases survive a restore untouched. A missing,
partial, or corrupt fixture fails closed before the runtime is started.

### `sanad-dev apply`

`apply` compares the working tree and every commit since the runtime's recorded
start commit with the decision table and executes the lightest correct action. It
prints the action, one reason per matched row, and up to three example paths.
`--dry-run` prints the decision only.

| Changed path | Action |
| --- | --- |
| docs, tests (`*/test/**`), `.github/**`, `**.md` except `client/assets/**` | none |
| `scripts/sanad_dev/**`, `scripts/sanad-dev*` | `stop` + `run` |
| `agent/**` | `restart agent` |
| `client/lib/main.dart`, `client/lib/driver_main.dart`, files containing `bootstrap`/`startup`, and files under a `di/` or `startup/` directory | `restart client` |
| `client/lib/l10n/**`, `client/l10n.yaml`, any `client/**.arb` | `stop` + `run` (localizations must be regenerated) |
| `client/pubspec.yaml`, `client/pubspec.lock`, `client/assets/**` (any extension), `client/{macos,windows,linux,web,ios,android}/**` | `stop` + `run` |
| other `client/lib/**.dart` | `reload client` |
| `shared/**`, `release/contract/**` | `restart agent` + `restart client` |
| anything else | `restart agent` + `restart client` |

`stop + run` subsumes every other action and `restart client` subsumes
`reload client`. Pubspec, asset, plugin, and native changes are compiled into the
desktop bundle, so a hot restart cannot apply them and they select `stop + run`.
An `.arb` or `l10n.yaml` change is build input for the generated
`app_localizations*.dart`, so a hot reload keeps showing the old strings and a hot
restart cannot regenerate them: it selects `stop + run`, and the printed reason
says the strings must be regenerated.
The documentation row deliberately runs before the asset row and matches
`client/assets/**` as an exception, so a `.md` or `.yaml` asset never falls into
`none`. A requested driver-mode change (the running pair has no
`lib/driver_main.dart` Client) also selects `stop + run`. The start commit is the
`source_commit` recorded in the launcher lease at launch; a lease that predates
that field yields a note and inspects the working tree only.

After a successful `apply`, the command records a per-path content snapshot in
`<runtime directory>/apply-baseline.json`: the repository-relative path of every
changed file mapped to a SHA-256 of the bytes that were applied (or the marker
`missing` for a deletion). The next run drops a candidate path only when its
current content still hashes to the recorded value, so an already-applied
working-tree edit is not reported twice and a second edit of the same file is. The
earlier whole-worktree signature could not do this: `git diff --name-only <start
commit>` reports a tracked working-tree edit on every call regardless of the
signature, so a tracked file repeated forever while only an untracked file
appeared idempotent.

The snapshot advances only for the paths whose actions actually ran. An action
skipped because its target — typically the Client — is not running stays
unrecorded, keeps the older commit baseline, and is reported again by the next
`apply`, which prints `Skipped …, start one, then rerun apply`.

### `status` is read-only

`status` performs discovery, reads the lease, and prints the projection. It never
starts, stops, restarts, repairs, or prepares anything. Before this contract, a
stale prepared runtime CLI triggered a hidden `auto-setup` during `status`; the
wrappers now fail with `Project runtime is stale. Run: sanad-dev setup` and leave
the environment untouched. Only `setup`, `run`, and `switch` prepare the runtime.

`status`, `stop`, and `logs` are read-only observation commands, so they are the
exception: when the prepared runtime CLI is stale they still run the last prepared
artifact, print `running the last prepared CLI` on stderr, and never rewrite the
stamp. Repairing failures stay fail-closed — a mutating command never uses a stale
artifact, and with no prepared artifact at all every command asks for `setup`.

`status` also prints the runtime source commit (`Runtime source commit:`) and the
product version (`Runtime version:`) from the Client pubspec. When the launcher
lease records a commit that value wins; a lease that predates the field, or no
lease at all, falls back to the worktree `HEAD`, so the line always names a commit
instead of a placeholder.

### `doctor` driver-host checks

`doctor` keeps its ownership diagnosis and adds report-only driver-host checks
after the ownership next-action line:

- **Driver entry point:** whether `client/lib/driver_main.dart` exists in the
  runtime source and how many lease-owned Clients were started from it.
- **Port and Home ownership:** the Agent and VM-service ports selected for this
  worktree with the current ownership class, plus the Home and whether it is
  worktree-scoped.
- **macOS grants:** Accessibility (`AXIsProcessTrusted`) and Screen Recording
  (`CGPreflightScreenCaptureAccess`) for the host that runs the driver, read
  through `dart:ffi` bindings on `ApplicationServices` and `CoreGraphics` in
  `scripts/sanad_dev/lib/src/infrastructure/macos_privacy_grants.dart`.

Both grants are passive preflight queries: they report the current grant without
prompting, so `doctor` never opens a TCC dialog and never needs an FVM, Dart, or
AppleScript subprocess. A grant that is absent reports `unknown — check System
Settings > Privacy & Security`; another platform reports `not applicable`.

The new checks never mutate state. `doctor --fix` keeps its existing narrow
stale-record repair and does not attempt to grant or change OS permissions.

### `sanad-dev refresh --at <+duration>`

`refresh` schedules an out-of-tree refresh that survives the tree it refreshes,
for remote test devices. `--at` accepts `+<n>s`, `+<n>m`, or `+<n>h` between one
minute and twelve hours; a bare `2m`, a zero delay, a negative or non-numeric
value, and anything above twelve hours are usage errors that schedule nothing. The
lower bound exists because the schedulers cannot represent a finer fire time, and
the upper bound keeps a stale schedule from outliving the source it was created
for.

| Platform | Scheduler |
| --- | --- |
| macOS | detached `sh` child (`ProcessStartMode.detached`), never launchd |
| Linux | `systemd-run --user --collect --unit=<task> --on-active=<seconds>` |
| Windows | `schtasks /Create /SC ONCE /ST <hh:mm>` with a script that deletes the task and itself |

The scheduled script receives the repository, branch, expected commit, runtime CLI
path, and Home as positional arguments (`$1`…`$6`) instead of interpolating them
into shell text, and every exit path deletes the script. Signals cancel the run:
`HUP`/`INT`/`TERM` delete the script and exit `129`/`130`/`143`, and the delay
itself runs as a background `sleep` that the script `wait`s on, so the trap fires
immediately instead of after the remaining delay. A trap that only deleted the
script would let the shell resume the interrupted command and still pull and
restart. Before touching anything the script refuses to continue when the branch
is not the recorded one or `HEAD` is no longer the commit that was current when
the schedule was created, so a schedule cannot land on unrelated new work.
Every git call runs with `GIT_TERMINAL_PROMPT=0` (and a `BatchMode` SSH command),
because a scheduled job has no terminal to answer a credential prompt.

A successful run performs `git -C <repo> pull --ff-only`, then `sanad-dev setup`
(the prepared runtime CLI must match the new source), then `sanad-dev restart
agent` and `sanad-dev restart client`, appending everything to
`<runtime directory>/refresh/<task>.log`, and finally deletes itself. When the
scheduler itself fails (`systemd-run`/`schtasks` non-zero, or a value `cmd.exe`
cannot represent), `refresh` prints the scheduler error, deletes the script it
just wrote, returns non-zero, and prints none of the success lines; a leftover
script with no schedule would look like a pending refresh. A Windows `/TR`
command line refuses a value containing `%` or `&`, because `cmd.exe` expands
`%NAME%` inside quotes and has no reliable escape for it. After scheduling,
`refresh` prints the task name, fire time, script path, log path, and the exact
verification commands (`git -C <repo> rev-parse HEAD`, `sanad-dev status`, bounded
Agent/Client logs).

### Restart build guard

`restart client`, `reload client`, `restart agent`, and the restart actions of
`apply` first check for a foreign build or test in the same worktree: one `ps`
(POSIX) or `Get-CimInstance Win32_Process` (Windows) query, filtered for a
command line that references the worktree root and invokes `flutter test`,
`dart test`, `flutter build`, `dart build`, `dart compile`, `flutter assemble`,
`xcodebuild`, `cargokit`, `flutter pub get`, or `dart pub get`. A path match must
be a real path boundary, and a quoted occurrence (a search pattern) is ignored.

When something is running, the command prints `Refusing to restart <worktree>`
with every matching PID and command line and returns nonzero instead of waiting
for an unbounded rebuild. `--force` skips the check.

Command lines are redacted before they are printed or logged. A token that looks
like a secret assignment (`--dart-define=SANAD_TOKEN=…`, `--api-key=…`,
`*PASSWORD*=`…) keeps its name and loses its value, including when the value is
nested inside a `--dart-define` payload, and a `--flag value` pair with a
secret-like flag name loses the separate value too. A header flag (`-H`,
`--header`, `-b`, `--cookie`) names no secret itself, so its value is redacted when
the header name before the first `:` is secret-like — `-H "Authorization: Bearer
…"`, `-H 'X-Api-Key: …'`, and a shell-split `-H Authorization: …` all lose the
value while `-H "Accept: application/json"` keeps it. The detector is a pure
function, so the printed list can be asserted in tests without spawning a build.

## Detached background launch


`sanad-dev run --background` is the official detached source-runtime command.
On POSIX hosts, the foreground requester starts the pinned runtime entry point in
`ProcessStartMode.detached`, preserving the caller worktree and arguments while
replacing the public flag with a private child marker. On Windows, standard
detached process creation inherits the caller's Job Object; when invoked from
short-lived tool shells or subagents subject to `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`,
closing the tool shell kills the detached launcher. Windows therefore launches the
background child through the CIM/WMI service (`Win32_Process.Create`), creating a
service-owned process that survives tool-shell closure without weakening lease,
ownership, or credential boundaries. The detached launcher—not the requester
shell—owns the Agent, Clients, journals, lease, and component control files.
Background mode suppresses terminal sidecars and stdout mirroring; component
output remains in the normal managed journals.

The requester does not claim success merely because spawn returned or because a
startup attempt diagnostic file records `managed`. To prevent premature success
declarations when a launcher is killed or components fail immediately after
attempt publication, the requester verifies that the child launcher process is
running and that the requested components are actively managed (with a valid
launcher lease, matching launcher process identity, and healthy target components).
After observing launcher death, the requester keeps a bounded two-second publication
grace so the child's atomic attempt and locator writes win over PID polling; it
then reports the staged result rather than a generic exit. Missing publication and
overall handshake timeout are nonzero failures with a direct `status` recovery
action. `--background` cannot be combined with `--dry-run`.

## Startup-attempt diagnostics

Before the launcher creates a managed lease, `run` creates a versioned startup
attempt under the resolved Sanad Home and a worktree-scoped locator under the
runtime metadata root. The attempt is diagnostic state, never ownership or
liveness evidence. It advances through `preflight`, `recordCreated`,
`componentsSpawned`, `readiness`, and `managed`; spawn/readiness failure records
`cleanup`, a bounded non-secret reason, and the CLI exit status after owned
process-tree cleanup. Journal attachment, terminal-adapter setup, and readiness
probing share the same orchestration guard, so an exception after spawn cannot
bypass tree cleanup. During startup, SIGINT and POSIX SIGTERM/SIGHUP enter one
idempotent abort path that terminates every spawned tree, closes journals,
deletes the lease, persists a staged interruption failure, then exits nonzero.
Once managed, POSIX SIGHUP follows the controller's normal complete-pair cleanup
rather than leaving supervised children behind.

The record preserves both the requested Home selector/path and the resolved
Home. Therefore later workspace-scoped commands can recover the resolved Home
as an authenticated discovery candidate, and `status` can explain a failed
explicit-Home launch without presenting the default worktree Home as if it were
the failed request. The locator is accepted only when its schema, worktree hash,
attempt id, Home record, and Agent port agree. Invalid or stale locators are
reported as diagnostics and cannot authorize mutation. A fresh `starting`
attempt projects its exact stage in `status` for at most the six-minute
component-control window, suppressing premature manual/orphaned/unverifiable
labels without granting mutation. Expired or terminal attempts defer entirely
to current process and lease evidence.

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
On Windows, the secure-file layer performs this hardening in process: it reads
and caches only the current process-token SID, builds a protected DACL containing
one full-control ACE for that SID, and applies it with `SetNamedSecurityInfoW`.
Atomic publication uses `MoveFileExW` with replace-existing and write-through
flags. It does not start PowerShell, and native failures retain the existing
typed ownership, replacement, or atomic-write outcomes.

Before creating or hardening a requested descendant, the layer lexically
normalizes both root and target and proves exact-root or descendant containment.
It then walks every segment without following links and rejects symlinks,
junctions, reparse points, and unsafe file types. A textual prefix such as
`home/../outside` therefore cannot escape and cannot cause an ancestor outside
the selected Home to be hardened. Temporary files are restricted before content
is written; successful replacement is followed by destination hardening on
Windows, while POSIX rename preserves the already-restricted inode.

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

CLI Client reload and restart first validate the exact managed launch profile,
PID, VM endpoint, Home, and launcher lease, then publish a bounded component-
control request to that launcher. The launcher revalidates the VM port against
its lease-owned process map and writes `r` or `R` to the original Flutter
process it owns. No second Flutter attach process is created, and an unrelated
or stale Client cannot receive the action.

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
