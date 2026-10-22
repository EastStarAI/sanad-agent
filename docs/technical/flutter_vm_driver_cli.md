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

- `client/lib/driver_main.dart` registers development-only VM extensions and starts the normal Client application. Flutter Driver text-entry emulation is disabled at binding creation so the operating-system text channel and physical keyboard remain active.
- `scripts/flutter_driver_cli/flutter_vm_controller.dart` owns VM RPC, isolate selection, action execution, post-condition verification, and connection cleanup.
- `scripts/flutter_driver_cli/cli_runner.dart` validates commands, applies the per-action deadline, and produces human-readable or machine-readable results.
- `scripts/flutter_driver_cli/tree_state.dart` owns the change-detection tree signature and the monotonic snapshot generation counter.
- `scripts/sanad_dev/lib/src/developer/developer_ui_driver.dart` resolves the current worktree's live driver Client, prepares the precompiled driver artifact, enforces the wall-clock cap, and forwards the VM endpoint to the standalone CLI.

## Startup Cost and Precompiled Artifact

A per-call `fvm dart scripts/flutter_driver_cli.dart` invocation pays FVM resolution, front-end compilation of the Flutter Driver import graph, and a fresh VM start before the first VM Service RPC. `sanad-dev ui` therefore compiles the CLI once into a native artifact and executes that artifact directly:

- The fingerprint covers `scripts/flutter_driver_cli.dart` plus every `scripts/flutter_driver_cli/**/*.dart` file. It is a change-detection value, not a security hash.
- The artifact lives at `.dart_tool/sanad-dev/flutter-driver-cli-<fingerprint>` and is produced by `fvm dart compile exe` with the Client package configuration, so the source-matched native binary carries the same Flutter Driver dependencies as the JIT path.
- A source change produces a new artifact; the previous artifact is pruned. A failed compilation, a missing Client package configuration, or a help request never leaves a partial artifact and falls back to the JIT invocation path.
- The launcher executes the artifact without a `dart` wrapper; FVM remains the only compiler owner.

Measured on a fake driver-enabled client (five runs per case): a JIT action cost 1.06-1.46 s per call, while the precompiled artifact answered `auth-url`/`snapshot` in 35-107 ms and a tap in 341 ms including its 300 ms post-delay. Cold artifact preparation is a one-time ~3 s compile per source fingerprint.

## Deadlines

Every action carries a hard deadline, and no driver path may block a caller indefinitely:

- The per-action deadline defaults to 30 s and is set with `--timeout <sec>`; it also bounds the VM Service RPC transport.
- `sanad-dev ui` additionally caps the whole child process at the action deadline plus a 10 s grace, plus `--wall-timeout <sec>` when a caller needs an explicit cap. Batch recipes scale the cap with the declarative step budget. A child that overruns is killed and the command exits `124` with a bounded diagnostic.
- `wait-for` polls bounded tree probes instead of the Flutter Driver extension, so waiting does not depend on animation-free frame synchronization.
- `scroll --until-visible` is driven by bounded offset scrolling plus tree probes. A target that is mounted without rendered bounds, that stops changing the tree, or that exceeds the deadline fails with `target offstage/not found; navigate first` instead of hanging.

## Post-Condition Verification

Action success is not treated as UI success:

- `tap` requires an observable widget-tree change, or the explicit `--expect <key>` / `--expect-absent <key>` assertion, within `--verify-timeout` (default 2000 ms). A silent no-op becomes a failed action that names `--expect`, `--no-verify`, and the navigation hypothesis.
- `enter-text` compares the target field's rendered text before and after. Observable text must match or change; an obscured field (whose value the Client never exposes) requires an observable tree change. `--no-verify` opts out explicitly for intentionally unobservable fields. The entered value is never echoed.
- `sanad-dev ui` activates the owning Client window on macOS before dispatching an action, using only the discovered Client process id and its own application bundle. This uses LaunchServices activation of the already-running bundle, so no Accessibility, Automation, or Keychain prompt is involved; every activation failure is a silent no-op.
- Verification evidence is additive in JSON: `verified` is `tree`, `key`, `text`, `present`, or `absent`; a failure reports `none`.

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

`auth-url` calls the dedicated `ext.sanad_client.auth_url` extension on the selected Client isolate. The extension reads only the in-memory active authentication challenge from the Client's registered `AuthService`, accepts only an absolute HTTP(S) URL, and fails when authentication is not currently in progress. It does not inspect heap instances, browser tabs, or another Client. The non-JSON command prints only the ephemeral URL to standard output so a caller can capture and immediately open it; failures use standard error. Neither layer persists the value or includes it in UI snapshots, managed journals, or runtime metadata. When more than one managed driver Client is active, `sanad-dev ui` requires an explicit `--vm-url` instead of selecting a Client implicitly.

Snapshot output is a flat list of typed elements with optional key, text, hint, tooltip, semantic label/role/selection state, and global bounds. Framework wrappers and icon-font glyphs may be suppressed, while tooltips and actionable semantics are consolidated into the keyed element. Obscured text-field values are never exposed. JSON mode emits one machine-parseable result object.

Snapshot JSON carries a monotonic `generation` and a tree `signature`. The generation counter is stored per Client VM Service authority outside the repository and increases on every command that reports it, so a caller can prove that a later snapshot is not an earlier one. `--fresh` re-captures until two consecutive trees agree and then reports the quiesced tree; because each invocation is stateless, quiescence is the only available freshness guarantee and no client-side frame pump is implied.

JSON payloads stay additive: existing keys keep their meaning, and actions may add `generation`, `verified`, `key`, `x`, and `y`. `wait-for` reports the elapsed wait as `duration_ms` plus `data.waited_ms`, so a caller never needs a sleep-poll loop.

Rendered conversation bodies expose event-scoped keys: `user_message_body:<eventId>` and `assistant_message_body:<eventId>`. The inspector reads plain text from `Text.data`, `Text.textSpan`, `RichText`, and `SelectableText`; for these message-body containers it joins rendered Markdown text leaves in display order and emits one consolidated keyed row rather than duplicate framework descendants. Callers can therefore use exact-key `find` or a filtered `snapshot` to verify message content without clipboard access. The event id remains the durable selector boundary, so a generic final-answer key must not be used when several messages are mounted.

## Safety and Portability

The interface is available only in driver builds and is not shipped as a production remote-control endpoint. VM Service access is equivalent to development-process control and must remain local or explicitly tunneled by the operator. No Local Gateway credential is sent to the VM Service.

The host CLI supports macOS, Windows, and Linux through Dart/FVM. Flutter platform support depends on the target exposing a reachable VM Service and launching the driver entry point; `sanad-dev` automatic discovery is limited to its managed worktree clients. Discovery is retried once before a missing-Client failure is reported, because a Client that is still finishing startup is transiently discoverable as absent.

`package:flutter_driver` remains a dependency only for `screenshot` capture. Tap, text entry, scrolling, and waiting are served by the Sanad VM extensions so they no longer depend on Flutter Driver frame synchronization.

The repository-level Dart analyzer excludes `scripts/flutter_driver_cli/` because that controller intentionally resolves Flutter Driver dependencies through the Client package configuration rather than a root Dart package. Its source remains covered through the explicit Client-configured CLI, focused test paths, and the native compilation gate.
