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
- `scripts/flutter_driver_cli/flutter_vm_controller.dart` owns VM RPC, isolate selection, Flutter Driver actions, and connection cleanup.
- `scripts/flutter_driver_cli/cli_runner.dart` validates commands and produces human-readable or machine-readable results.
- `scripts/sanad_dev/developer_actions.dart` resolves the current worktree's live driver client and forwards its VM endpoint to the standalone CLI.

## Interaction Contract

The public primitives are snapshot, find, tap, enter-text, scroll, wait-for, screenshot, and batch. Selectors use widget keys, exact text, widget types, explicit indexes, coordinates, and optional subtree scope.

`enter-text` first focuses the requested field, then calls the Sanad
`ext.sanad_client.enter_text` extension. The extension resolves an exact keyed
`EditableTextState` (or the focused editable when no key is supplied) and sends
one `TextEditingValue` through `updateEditingValue`, preserving user-change
semantics without mocking `SystemChannels.textInput`. It never returns the text
value. The controller falls back to legacy Flutter Driver `enterText` only for
older instrumented Clients that do not advertise the Sanad extension.

The controller selects the isolate that advertises the required extension rather than assuming the first VM isolate is the Flutter UI isolate. Missing scopes and invalid indexes fail closed. Scoped, indexed, and coordinate taps never fall back to an unscoped selector. Offset scrolling uses the custom extension and emits user-scroll intent before moving the viewport, so pagination, follow opt-out, and viewport persistence react as they do to mouse or trackpad input. The returned offset and min/max extents are measured after the motion. Scroll-until-visible remains a Flutter Driver operation and succeeds only after the target becomes visible.

Snapshot output is a flat list of typed elements with optional key, text, hint, tooltip, semantic label/role/selection state, and global bounds. Framework wrappers and icon-font glyphs may be suppressed, while tooltips and actionable semantics are consolidated into the keyed element. Obscured text-field values are never exposed. JSON mode emits one machine-parseable result object.

## Safety and Portability

The interface is available only in driver builds and is not shipped as a production remote-control endpoint. VM Service access is equivalent to development-process control and must remain local or explicitly tunneled by the operator. No Local Gateway credential is sent to the VM Service.

The host CLI supports macOS, Windows, and Linux through Dart/FVM. Flutter platform support depends on the target exposing a reachable VM Service and launching the driver entry point; `sanad-dev` automatic discovery is limited to its managed worktree clients.

The repository-level Dart analyzer excludes `scripts/flutter_driver_cli/` because that controller intentionally resolves Flutter Driver dependencies through the Client package configuration rather than a root Dart package. Its source remains covered through the explicit Client-configured CLI and focused test paths.
