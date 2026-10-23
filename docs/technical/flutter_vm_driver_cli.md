---
title: "Flutter VM Driver CLI Architecture"
description: "Driver-enabled Client instrumentation, standalone CLI boundaries, deterministic UI selectors, and VM Service safety."
---

# Flutter VM Driver CLI Architecture

## Purpose

The Flutter VM Driver CLI provides an agent-facing control surface for a driver-enabled Sanad Client when desktop accessibility metadata is insufficient. It exposes deterministic inspection and interaction primitives analogous to browser/device automation while preserving Flutter's platform-neutral widget runtime.

## Boundary

The host CLI is implemented under `scripts/flutter_driver_cli/` and does not import `sanad-dev` runtime internals. It does depend on Flutter Driver packages supplied by the Client package configuration. The target is not an arbitrary Flutter application: it must start through `client/lib/driver_main.dart`, which registers Flutter Driver plus the Sanad inspection, scroll, and tap service extensions.

Desktop worktree discovery belongs to `sanad-dev ui`. Standalone, mobile, and web use require an explicit reachable VM Service endpoint. The standalone CLI never selects an arbitrary process from the host process table.

## Components

- `client/lib/driver_main.dart` registers development-only VM extensions in documented order and starts the normal Client application. Flutter Driver text-entry emulation is disabled at binding creation so the operating-system text channel and physical keyboard remain active.
- `client/lib/driver/` hosts modular driver helpers: `driver_widget_filters.dart` (noise suppression, key filters, scope root resolution), `inspect_ui_extension.dart` (`ext.sanad_client.inspect_ui`), `interaction_extensions.dart` (`ext.sanad_client.enter_text`, `ext.sanad_client.scroll`, `ext.sanad_client.tap`, `ext.sanad_client.reveal`), `ui_inspection_state.dart` (enabled state resolution), `ui_inspection_text.dart` (rendered text extraction), and `ui_type_census.dart` (bounded type walks).
- `scripts/flutter_driver_cli/flutter_vm_controller.dart` owns VM RPC, isolate selection, action execution, post-condition verification, and connection cleanup.
- `scripts/flutter_driver_cli/cli_runner.dart` validates commands, applies the per-action deadline, and produces human-readable or machine-readable results.
- `scripts/flutter_driver_cli/tree_state.dart` owns the change-detection tree signature and the monotonic snapshot generation counter.
- `scripts/sanad_dev/lib/src/developer/developer_ui_driver.dart` resolves the current worktree's live driver Client, prepares the precompiled driver artifact, enforces the wall-clock cap, and forwards the VM endpoint to the standalone CLI.

## Startup Cost and Precompiled Artifact

A per-call `fvm dart scripts/flutter_driver_cli.dart` invocation pays FVM resolution, front-end compilation of the Flutter Driver import graph, and a fresh VM start before the first VM Service RPC. `sanad-dev ui` therefore compiles the CLI once into a native artifact and executes that artifact directly:

- The fingerprint covers `scripts/flutter_driver_cli.dart`, every `scripts/flutter_driver_cli/**/*.dart` file, the resolved Client package configuration (`client/.dart_tool/package_config.json`), the locked dependency graph (`client/pubspec.lock`), the FVM pin (`.fvmrc`), and the Dart SDK version of the launcher. A dependency or SDK change would otherwise execute a stale binary against a new Flutter API surface, so all of them invalidate the artifact. It is a change-detection value, not a security hash.
- The artifact lives at `.dart_tool/sanad-dev/flutter-driver-cli-<fingerprint>` and is produced by `fvm dart compile exe` with the Client package configuration, so the source-matched native binary carries the same Flutter Driver dependencies as the JIT path. Compilation has its own three-minute deadline and is killed with its whole process tree when it overruns.
- A source change produces a new artifact; the previous artifact is pruned. Staging files written by another live invocation (`<artifact>.<pid>.tmp`) are never pruned while they are fresh, so two concurrent invocations cannot delete each other's build.
- A failed compilation, a missing Client package configuration, or a help request never leaves a partial artifact and falls back to the JIT invocation path. An artifact that disappears between the cache check and the spawn, or that is no longer executable, also retries through the JIT path instead of failing the action.
- The launcher executes the artifact without a `dart` wrapper; FVM remains the only compiler owner.

Measured on a fake driver-enabled client (five runs per case): a JIT action cost 1.06-1.46 s per call, while the precompiled artifact answered `auth-url`/`snapshot` in 35-107 ms and a tap in 341 ms including its 300 ms post-delay. Cold artifact preparation is a one-time ~3 s compile per source fingerprint, and that cost is reported as `build_ms` in the JSON of the call that paid it (`sanad-dev ui` passes it through the child environment), so a slow first action is attributable instead of looking like a slow snapshot.

## Warm Invocation Budget

A warm `sanad-dev ui` invocation is two process starts plus one VM Service round trip, so every fixed cost in front of the driver is user-visible. Three of them were removed because they did work the action never consumed:

- **Wrapper freshness.** The POSIX wrapper used to hash every runtime CLI source file in its own `shasum` process, which cost roughly half a second per invocation before any Dart code ran. It now asks Git instead: when `git status` reports no change in the watched inputs (`pubspec.yaml`, `pubspec.lock`, and `lib/**/*.dart`), the working tree content is exactly the staged blobs, so the fingerprint is one hash of one `git ls-files --stage` listing. A tracked edit, an untracked file under the watched paths, an ignore change, a deletion, or a branch switch all make that status non-empty and fall back to the previous per-file content hash, so the fast path can never mask a rebuild. The fingerprint is change detection, not a security boundary, and a checkout without Git keeps the content-hash path. The Windows wrapper still hashes each source file.
- **Port-resolution prelude.** The CLI resolved an agent/client port for every command that reached the client-attach dispatch, and `ui` never read the result. `driver`/`ui` are now dispatched before that resolution, which removes a full process scan plus a 101-port sweep from the warm path.
- **Target discovery.** The adapter resolved the managed driver Client with a full process-table scan, a 101-port Agent sweep across every candidate Home, and the lease validation, and paid it again on the retry. It now remembers the resolved Client in `<runtime directory>/ui-driver-target.json` (owner-only, `0600`, keyed by worktree id and Sanad Home) and revalidates that entry instead: the loopback endpoint must accept a connection, the recorded development-service and runner pids must still present the same argument vectors, the Agent must answer health on the recorded port, and the launcher lease must still name exactly that Client and VM-service port. Every one of those observations is live evidence; the entry only says where to look. A rejection, an unreadable or foreign entry, or a lease whose client set changed (a second Client started, a Client restarted) discards the entry and falls back to the full scan, which also preserves the "exactly one managed Client" failure mode. Discovery gained matching `candidatePids`/`candidatePorts` narrowing for that purpose; a narrowed scan reads the same live evidence for the subset it was given and never treats an empty result as absence.

Measured on a warm checkout against a loopback VM Service stub, five runs each, with an explicit `--vm-url` so the numbers isolate the fixed cost in front of the driver:

| Stage | Before | After |
| --- | --- | --- |
| Wrapper fingerprint (45 sources) | ~500 ms | ~40 ms (two Git reads) |
| CLI prelude (home inference + unused port resolution) | ~130 ms | ~65 ms |
| Client resolution (full scan, cold entry) | ~140 ms clients + ~245-1400 ms Agent sweep | ~105 ms revalidated entry |
| Driver artifact lookup + spawn + snapshot | ~30-60 ms | ~30-60 ms |
| Whole warm `ui snapshot --json` (no target discovery) | 1283 ms (min) | 217 ms (min) |

The remaining fixed cost is one Git-based runtime discovery for post-launch Home inference (~65 ms), one for the UI adapter's repository root (~40 ms), and one owner-only state read for the revalidated entry (~15 ms). A persistent per-worktree driver connection was therefore not added: it would have saved a ~10-30 ms attach at the cost of a new long-lived local surface. If the remaining budget ever needs to shrink again, that helper is the next step — one worktree-scoped process holding the VM Service socket, loopback or unix only, `0600` socket permissions, idle exit, and a lifetime bound to the resolved Client pid so it can never outlive its runtime.

## Deadlines

Every action carries a hard deadline, and no driver path may block a caller indefinitely:

- The per-action deadline defaults to 30 s and is set with `--timeout <sec>`; it also bounds the VM Service RPC transport.
- A batch recipe has one deadline source: a step that declares no `timeout_seconds` inherits the batch `--timeout`, and the transport timeout covers the longest step in the recipe. The launcher budgets the wall clock from that same `--timeout`, so the enforced deadline can neither outlive nor be cut short by the cap.
- `sanad-dev ui` caps the whole child process at the action deadline plus its post-delay and verification window plus a 10 s grace, and `--wall-timeout <sec>` replaces that cap explicitly. A batch recipe is capped by the sum of every step's own `timeout_seconds` (or the batch `--timeout` when the step declares none), `delay_ms`, `verify` window, and `sleep_ms` plus the same grace, so one slow step is not hidden behind a step count.
- `--wall-timeout <sec>` is a launcher-only option (`sanad-dev ui`), never forwarded to the driver: the driver's `--timeout` stays the action's own deadline, while `--wall-timeout` bounds the whole child process including attachment, FVM wrapper and compiler. It is the only way to prove a hang without also loosening the action deadline, because the derived cap always exceeds the action deadline by design. `sanad-dev ui -h` lists it under `Launcher Options` with `--home`, `--activate`, and `--no-activate`.
- A child that overruns is killed together with every descendant process, so the `dart` grandchild behind an `fvm` wrapper cannot keep driving the UI after the command has exited. POSIX resolves the tree from the process table and signals it deepest first; Windows uses `taskkill /T /F`. The command then exits `124` with a bounded diagnostic.
- A killed batch still reports the steps that completed: the driver persists each step to the `--report-file` the launcher injects before it starts the next one, and the launcher reproduces those results as partial evidence (`timed_out: true`, `partial: true`, `steps_total`, `completed`).
- `wait-for` polls bounded tree probes instead of the Flutter Driver extension, so waiting does not depend on animation-free frame synchronization. A failed wait always names the target, the observed state, and the elapsed time (`<target> was not found after Nms; presence not observed across N probe(s)`); a bare `Timed out` is never emitted.
- `scroll --until-visible` is driven by bounded offset scrolling plus tree probes. A target that is mounted without rendered bounds, that stops changing the tree, or that exceeds the deadline fails with `target offstage/not found; navigate first` instead of hanging.

## Post-Condition Verification

Action success is not treated as UI success, and an unobservable action is never reported as a verified one:

- `tap` observes the widget tree around the dispatch. The baseline is captured *after* `ext.sanad_client.reveal` has scrolled the target into view, so a scroll is never credited to the tap. A plain `tap` that observes no change still exits `0`, reporting `verified: false` with `verification: no_observable_change` and a message that names the tap as already dispatched, because turning every inert control into a failure would break legitimate no-op targets and blind retries of non-idempotent actions are worse than a reported no-change. When the Client does not register `ext.sanad_client.reveal`, the weaker baseline is named on the verified path too: auto-scroll may be the change that was observed.
- `--verify`, `--expect <key>`, or `--expect-absent <key>` make that same condition a failure. The failure and no-change messages both contain `tap dispatched; no observable change` so a caller cannot mistake a silent no-op for a delivered action.
- `enterText` compares the target field's rendered text before and after. Observable text must match or change. When the field's value is not exposed (obscured input, or an empty field that emits no text), verification falls back to an observable widget-tree change even when the field was selected by `--key`; `--no-verify` opts out explicitly. The entered value is never echoed.
- `sanad-dev ui` activates the owning Client window on macOS before dispatching an action that changes the UI (tap, enter-text, scroll, batch) and never for read-only commands (snapshot, find, wait-for, screenshot). It uses only the discovered Client process id and its own application bundle: the pid must still be alive, must still belong to that bundle, and must be the only live instance of it, otherwise activation is skipped instead of guessing or launching a second Client. Every activation failure is a silent no-op, and `--no-activate` disables it.
- Verification evidence is typed, not overloaded. `verified` is always a boolean and `verification` is always one of `key`, `present`, `absent`, `text`, `tree`, `no_observable_change`, `none`, or `type_census`. `key`, `present`, `absent`, `text`, and `tree` prove the post-condition and pair with `verified: true`; the other three pair with `verified: false`. The channel describes what was observed, not what the caller asked for: an inert tap reports `no_observable_change` whether or not `--verify` was passed, and only the exit status differs. `none` means no evidence channel produced a verdict (verification disabled with `--no-verify`, the action failed before observation, or a batch step such as `snapshot`/`sleep` asserts no post-condition), and `type_census` means the rendered type census proved the requested absence is unprovable at that moment. Both fields are always present on an action result, so a strict consumer can type them once instead of sniffing for a string.

## Interaction Contract

The public primitives are snapshot, find, tap, enter-text, scroll, wait-for, screenshot, and batch. Selectors use widget keys, exact text, widget types, explicit indexes, coordinates, and optional subtree scope. Batch recipes also expose a bounded `message_bodies` evidence step that returns at most the latest 50 event-scoped user and assistant message bodies, with total count and explicit truncation metadata, before the shared Driver connection closes.

`enter-text` first focuses the requested field, then calls the Sanad
`ext.sanad_client.enter_text` extension. The extension resolves an exact keyed
`EditableTextState` (or the focused editable when no key is supplied) and sends
one `TextEditingValue` through `updateEditingValue`, preserving user-change
semantics without mocking `SystemChannels.textInput`. It never returns the text
value. The command requires the Sanad extension: a Client that does not advertise
it fails closed instead of degrading to an unscoped legacy text entry.

The controller selects the isolate that advertises the required extension rather than assuming the first VM isolate is the Flutter UI isolate, and reuses that isolate for the rest of the invocation. Missing scopes and invalid indexes fail closed. Scoped, indexed, and coordinate taps never fall back to an unscoped selector. Offset scrolling uses the custom extension and emits user-scroll intent before moving the viewport, so pagination, follow opt-out, and viewport persistence react as they do to mouse or trackpad input. The returned offset and min/max extents are measured after the motion.

A selector tap reveals its target first through the dedicated `ext.sanad_client.reveal` extension, which shares the tap locator and never dispatches a pointer event. Reveal is a separate extension rather than a `tap` parameter on purpose: a Client that does not register it fails at isolate discovery, so an older Client degrades to an unrevealed baseline instead of receiving an unexpected extra tap.

`auth-url` calls the dedicated `ext.sanad_client.auth_url` extension on the selected Client isolate. The extension reads only the in-memory active authentication challenge from the Client's registered `AuthService`, accepts only an absolute HTTP(S) URL, and fails when authentication is not currently in progress. It does not inspect heap instances, browser tabs, or another Client. The non-JSON command prints only the ephemeral URL to standard output so a caller can capture and immediately open it; failures use standard error. Neither layer persists the value or includes it in UI snapshots, managed journals, or runtime metadata. When more than one managed driver Client is active, `sanad-dev ui` requires an explicit `--vm-url` instead of selecting a Client implicitly.

Snapshot output is a flat list of typed elements with optional key, text, hint, tooltip, semantic label/role/selection state, and global bounds. Framework wrappers and icon-font glyphs may be suppressed, while tooltips and actionable semantics are consolidated into the keyed element. Obscured text-field values are never exposed. JSON mode emits one machine-parseable result object.

That projection omits unkeyed widgets that carry no text, tooltip, or interaction, so an inspected absence is not proof of absence: a `CircularProgressIndicator`, for example, is rendered but never emitted. Type-based waiting therefore consults a separate rendered type census (`ext.sanad_client.inspect_ui` with `typeCensus: true`), which enumerates runtime widget types for the scoped subtree with an explicit `truncated` flag and the number of elements walked. The census is bounded by the walk it performs (`client/lib/driver/ui_type_census.dart`), never by the number of distinct types it collects: a large Client renders hundreds of distinct widget types, and a type-count cap would mark every such tree truncated and make every absence claim unprovable. `wait-for --absent --type` succeeds only when the census proves the type is not rendered and fails closed when the census was truncated, reporting `type census truncated` as the reason rather than a timeout, because waiting longer cannot complete a walk the Client bounded on purpose; `wait-for --type` reports that the type is rendered but not inspected instead of waiting out the timeout for a type the snapshot cannot represent.

A complete census that still contains the type is not a verdict: a spinner rendered now may finish later, so the poll continues to the deadline and only then fails with `<type> is still rendered (proven by the rendered type census) after Nms; absence not observed`, carrying `data.evidence: "type_census"`, `data.still_rendered: true`, and `verification: "type_census"`. A caller that cannot wait passes `--no-wait` (or `no_wait: true` on a batch step) to judge the first census immediately; the diagnostic then says `after a single check (Nms)`. This keeps both outcomes honest: waiting is never silently capped at the first observation, and the failure always carries the evidence that produced it.

Snapshot JSON carries a monotonic `generation` and a tree `signature`. The generation counter is stored per Client VM Service authority outside the repository and is incremented under an advisory lock, so two concurrent invocations cannot return the same value; the key is derived from the resolved endpoint, never from a raw argument or the URL's authentication token. `--fresh` re-captures until two consecutive trees agree and then reports the quiesced tree plus `settled: true`; when the window expires first it still returns the last tree but reports `settled: false`, so a caller can distinguish quiescence from a truncated wait. `fresh` therefore means "this capture used the `--fresh` path" and is `false` on every default snapshot, where no quiescence was attempted and `settled` is omitted.

JSON payloads stay additive: existing keys keep their meaning, and actions may add `generation`, `verified`, `verification`, `key`, `x`, and `y`. `wait-for` reports the elapsed wait as `duration_ms` plus `data.waited_ms`, so a caller never needs a sleep-poll loop. A call that had to compile the driver artifact also reports `build_ms`, the compile time it paid; a call served from the cached artifact omits the field rather than reporting zero. Batch JSON also reports `steps_total` next to `total`, because a recipe that stopped at a failed step has fewer results than steps.

Rendered conversation bodies expose event-scoped keys: `user_message_body:<eventId>` and `assistant_message_body:<eventId>`. The inspector reads plain text from `Text.data`, `Text.textSpan`, `RichText`, and `SelectableText`; for these message-body containers it joins rendered Markdown text leaves in display order and emits one consolidated keyed row rather than duplicate framework descendants. Callers can therefore use exact-key `find` or a filtered `snapshot` to verify message content without clipboard access. The event id remains the durable selector boundary, so a generic final-answer key must not be used when several messages are mounted.

## Safety and Portability

The interface is available only in driver builds and is not shipped as a production remote-control endpoint. VM Service access is equivalent to development-process control and must remain local or explicitly tunneled by the operator. No Local Gateway credential is sent to the VM Service.

The host CLI supports macOS, Windows, and Linux through Dart/FVM. Flutter platform support depends on the target exposing a reachable VM Service and launching the driver entry point; `sanad-dev` automatic discovery is limited to its managed worktree clients. Discovery is retried once before a missing-Client failure is reported, because a Client that is still finishing startup is transiently discoverable as absent.

`package:flutter_driver` remains a dependency only for `screenshot` capture. Tap, text entry, scrolling, and waiting are served by the Sanad VM extensions so they no longer depend on Flutter Driver frame synchronization.

The repository-level Dart analyzer excludes `scripts/flutter_driver_cli/` because that controller intentionally resolves Flutter Driver dependencies through the Client package configuration rather than a root Dart package. Its source remains covered through the explicit Client-configured CLI, focused test paths, and the native compilation gate.
