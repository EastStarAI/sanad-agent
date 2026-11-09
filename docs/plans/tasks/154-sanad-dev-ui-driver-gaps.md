# Task 154 — sanad-dev UI driver gaps found by a live tester

## Goal

Close the driver-tooling gaps that blocked honest verification in the Voice02 local dictation run
(`~/.sanad-delegate/runs/voice02-fullstack-20261108-b999/live-local/RESULT.md`, Skill evaluation items 1–3):
express a long press, hover a row so its hover-only affordance appears, call any `ext.sanad_client.*` extension
through the existing discovery path, name an obscured tap target instead of reporting a silent no-change, and
expose a widget's tooltip text in the inspected snapshot.

## Locked decisions and scope

- **Long press** is a parameter of the existing pointer sequence, not a new extension: `tap --hold-ms <n>` and a
  `hold_ms` batch field. The Client owns the bound (5000 ms) and the CLI rejects an out-of-range value before it
  connects, so a bad request never reaches the pointer sequence.
- **Hover** is one synthetic in-app pointer with a guaranteed exit: `hover --key <k> --ms <n>` and a `hover_ms`
  batch field. The events are dispatched into the Client's own pointer pipeline, so `MouseRegion.onEnter/onExit`
  and hover-only `Visibility` react without operating-system input, window focus, or an accessibility grant. The
  dwell defaults to 2000 ms, is bounded at 5000 ms in both layers, and the Client keeps its own automatic exit at
  the dwell plus 500 ms. The command is two phases (`enter`, `exit`) rather than one blocking call so the caller
  can capture the tree *while* the affordance is visible; the exit always runs, including after a failed verdict.
- **Generic extension call** reuses `sanad-dev ui`'s existing managed-Client discovery (`--vm-url` injection) and the
  driver's required-extension isolate selection. Only names under the `ext.sanad_client.` prefix are accepted; the
  VM Service is a development control surface, not a general-purpose RPC proxy. `ext` never takes window focus and
  prints one JSON document.
- **Obscured target** is a new evidence channel (`verification: obscured`) reported when the target's hit test does
  not include the element. No pointer event is dispatched in that case: the previous behavior tapped whatever was
  painted on top, which in the reported run landed on a different device row. The blocker's bounds and, when a
  bounded probe finds one, its key are reported. Hover deliberately does not inherit this refusal — a hover cannot
  click — and reports the blocker as information instead.
- **Tooltip text** is projected for a keyed element whose `Tooltip` is a descendant (`IconButton(tooltip: ...)`
  builds it as a child), which the ancestor-only propagation never reached. The message is bounded to 200 characters
  with explicit `tooltip_truncated` metadata.
- **Out of scope:** the dictation feature files (owned by PR 337), driver keys for new product widgets, and any
  policy change to the tester skill (Round C owns skill policy; this task only adds the new commands to its
  reference).

## Gates

### G0 — Contracts and evidence
- [x] Read `AGENTS.md`, `docs/llms.txt`, `scripts/sanad_dev/AGENTS.md`, `scripts/flutter_driver_cli/AGENTS.md`,
      `client/AGENTS.md`, `docs/technical/flutter_vm_driver_cli.md`, and the tester skill reference.
- [x] Record the gaps and their evidence anchors from the Voice02 RESULT.

### G1 — Tests first
- [x] CLI parsing tests: `tap --hold-ms` in range forwards `hold_ms`; out of range and non-numeric fail before any
      connection; `ext` requires an `ext.sanad_client.` name and rejects every other prefix, invalid `--args` JSON,
      and non-scalar argument values before connecting.
- [x] CLI hover tests: `--ms` in range is forwarded as the dwell of both phases, out of range and non-numeric fail
      before connecting, a missing target fails before connecting, `--no-verify` skips the baseline, a covered target
      is dispatched with the blocker named, and a failed expectation still exits the pointer.
- [x] Wall-clock tests: a tap hold extends the launcher cap, a batch `hold_ms` extends the batch budget, a hover dwell
      extends the action cap, a batch `hover_ms` extends the batch budget, and `--ms` stays a forwarded driver value.
- [x] Client helper tests: hold parsing bounds, obscured hit-path detection (a covered target versus an uncovered
      one), descendant tooltip discovery, tooltip bounding, and the descendant-tooltip projection of a keyed
      `IconButton`.
- [x] Client hover tests: dwell parsing bounds and a widget test proving `MouseRegion.onEnter` fires on the synthetic
      enter and `onExit` on the synthetic exit, including the automatic exit and its cancellation, plus a
      reveal-only (`Visibility(maintainState: true)`) row whose projected bounds move on enter and return on exit —
      the evidence a hover on that pattern can actually produce.
- [x] Driver/model tests: `hold_ms` and `hover_ms` serialize on a batch step, and `obscured` is a documented
      verification channel that reports `verified: false`.

### G2 — Implementation
- [x] Client: `hold_ms` on `ext.sanad_client.tap` (bounded, validated), obscured detection plus blocker description,
      the bounded descendant tooltip projection, and the two-phase `ext.sanad_client.hover` with its bounded
      automatic exit.
- [x] Driver CLI: `tap --hold-ms`, `hover --ms`, `--hold-ms`/`hold_ms` and `--ms`/`hover_ms` validation, the `ext`
      command, the `obscured` channel, and usage text.
- [x] `sanad-dev ui`: forward the new value flags, include the hold and the hover dwell in the wall-clock budgets, keep
      `ext` and `hover` out of the window-activating command set, and list `hover` in `sanad-dev ui -h`.

### G3 — Documentation
- [x] `docs/technical/flutter_vm_driver_cli.md`: the new commands, parameters, channels, and tooltip projection.
- [x] `docs/qa_maintenance/flutter_vm_driver_cli_qa.md`: one row per new verified behavior.
- [x] `scripts/flutter_driver_cli/AGENTS.md`: the allowlist law, the long-press and hover bounds, and the channel set.
- [x] `.agents/skills/sanad-client-tester/references/interactive-ui-testing.md`: the new commands only.

## Acceptance Criteria

- [x] `sanad-dev ui tap --key <k> --hold-ms 800` registers a long press on a driver-enabled Client, and the same
      command with a value above the bound exits nonzero naming the bound without connecting.
- [x] A batch recipe accepts `"hold_ms": <n>` on a tap step, forwards it, and budgets the wall clock for it.
- [x] `sanad-dev ui hover --key <k> --ms 800 --expect <hover_key>` enters the target, observes the hovered tree, and
      removes the pointer again; `--ms` above 5000, negative, or non-numeric exits nonzero naming the bound without
      connecting, and a batch `hover_ms` forwards the same dwell.
- [x] `sanad-dev ui ext --name ext.sanad_client.inspect_ui --args '{"onlyWithKeys":"true"}'` prints the extension's
      JSON result, and `--name ext.flutter.reassemble` is refused.
- [x] A tap whose target is covered by an overlay reports `verification: obscured` with the blocker's bounds and
      dispatches no pointer event.
- [x] `snapshot`/`find` expose the tooltip message of a keyed element whose `Tooltip` is a child, bounded to 200
      characters with `tooltip_truncated` when cut.
- [x] `fvm dart analyze` and `fvm dart test` pass in `scripts/sanad_dev`; `fvm flutter analyze` and the focused
      driver tests pass in `client/`.
- [ ] Live acceptance on the coordinator's runtime: a hovered sidebar row lays its hover-only menu out while the
      pointer rests on it and collapses it again afterwards. The menu stays mounted inside a
      `Visibility(maintainState: true)`, so the observed change is layout: `--verify` passes through
      `verification: tree`, and the menu's key is not used as the proof.

## Definition of Done

- Analyzer and focused tests above are green, with output kept to the final five lines while preserving exit status.
- Owning documentation and the tester skill reference describe the new commands; no new policy rule is added to the
  skill.
- `graphify update .` is run after the code changes.
- The change lands as one focused pull request against `main`; live acceptance runs on the coordinator's runtime,
  never from this task.

## Current status

Implementation, static verification, and documentation complete. Live acceptance of the hovered row menu is the one
remaining gate and runs on the coordinator's runtime.
