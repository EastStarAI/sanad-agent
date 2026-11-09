# Task 147 — sanad-dev UI driver gaps found by a live tester

## Goal

Close the four driver-tooling gaps that blocked honest verification in the Voice02 local dictation run
(`~/.sanad-delegate/runs/voice02-fullstack-20261108-b999/live-local/RESULT.md`, Skill evaluation items 1–3):
express a long press, call any `ext.sanad_client.*` extension through the existing discovery path, name an
obscured tap target instead of reporting a silent no-change, and expose a widget's tooltip text in the inspected
snapshot.

## Locked decisions and scope

- **Long press** is a parameter of the existing pointer sequence, not a new extension: `tap --hold-ms <n>` and a
  `hold_ms` batch field. The Client owns the bound (5000 ms) and the CLI rejects an out-of-range value before it
  connects, so a bad request never reaches the pointer sequence.
- **Generic extension call** reuses `sanad-dev ui`'s existing managed-Client discovery (`--vm-url` injection) and the
  driver's required-extension isolate selection. Only names under the `ext.sanad_client.` prefix are accepted; the
  VM Service is a development control surface, not a general-purpose RPC proxy. `ext` never takes window focus and
  prints one JSON document.
- **Obscured target** is a new evidence channel (`verification: obscured`) reported when the target's hit test does
  not include the element. No pointer event is dispatched in that case: the previous behavior tapped whatever was
  painted on top, which in the reported run landed on a different device row. The blocker's bounds and, when a
  bounded probe finds one, its key are reported.
- **Tooltip text** is projected for a keyed element whose `Tooltip` is a descendant (`IconButton(tooltip: ...)`
  builds it as a child), which the ancestor-only propagation never reached. The message is bounded to 200 characters
  with explicit `tooltip_truncated` metadata.
- **Out of scope:** the dictation feature files (owned by PR 337), driver keys for new product widgets, and any
  policy change to the tester skill (Round C owns skill policy; this task only adds the new commands to its
  reference).

## Gates

### G0 — Contracts and evidence
- [ ] Read `AGENTS.md`, `docs/llms.txt`, `scripts/sanad_dev/AGENTS.md`, `scripts/flutter_driver_cli/AGENTS.md`,
      `client/AGENTS.md`, `docs/technical/flutter_vm_driver_cli.md`, and the tester skill reference.
- [ ] Record the four gaps and their evidence anchors from the Voice02 RESULT.

### G1 — Tests first
- [ ] CLI parsing tests: `tap --hold-ms` in range forwards `hold_ms`; out of range and non-numeric fail before any
      connection; `ext` requires an `ext.sanad_client.` name and rejects every other prefix, invalid `--args` JSON,
      and non-scalar argument values before connecting.
- [ ] Wall-clock tests: a tap hold extends the launcher cap, and a batch `hold_ms` extends the batch budget.
- [ ] Client helper tests: hold parsing bounds, obscured hit-path detection (a covered target versus an uncovered
      one), descendant tooltip discovery, tooltip bounding, and the descendant-tooltip projection of a keyed
      `IconButton`.
- [ ] Driver/model tests: `hold_ms` serializes on a batch step, and `obscured` is a documented verification channel
      that reports `verified: false`.

### G2 — Implementation
- [ ] Client: `hold_ms` on `ext.sanad_client.tap` (bounded, validated), obscured detection plus blocker description,
      and the bounded descendant tooltip projection.
- [ ] Driver CLI: `tap --hold-ms`, `--hold-ms`/`hold_ms` validation, the `ext` command, the `obscured` channel, and
      usage text.
- [ ] `sanad-dev ui`: forward the new value flags, include the hold in the wall-clock budgets, and keep `ext` out of
      the window-activating command set.

### G3 — Documentation
- [ ] `docs/technical/flutter_vm_driver_cli.md`: the new command, parameter, channel, and tooltip projection.
- [ ] `docs/qa_maintenance/flutter_vm_driver_cli_qa.md`: one row per new verified behavior.
- [ ] `scripts/flutter_driver_cli/AGENTS.md`: the allowlist law, the long-press bound, and the channel set.
- [ ] `.agents/skills/sanad-client-tester/references/interactive-ui-testing.md`: the new commands only.

## Acceptance Criteria

- [ ] `sanad-dev ui tap --key <k> --hold-ms 800` registers a long press on a driver-enabled Client, and the same
      command with a value above the bound exits nonzero naming the bound without connecting.
- [ ] A batch recipe accepts `"hold_ms": <n>` on a tap step, forwards it, and budgets the wall clock for it.
- [ ] `sanad-dev ui ext --name ext.sanad_client.inspect_ui --args '{"onlyWithKeys":"true"}'` prints the extension's
      JSON result, and `--name ext.flutter.reassemble` is refused.
- [ ] A tap whose target is covered by an overlay reports `verification: obscured` with the blocker's bounds and
      dispatches no pointer event.
- [ ] `snapshot`/`find` expose the tooltip message of a keyed element whose `Tooltip` is a child, bounded to 200
      characters with `tooltip_truncated` when cut.
- [ ] `fvm dart analyze` and `fvm dart test` pass in `scripts/sanad_dev`; `fvm flutter analyze` and the focused
      driver tests pass in `client/`.

## Definition of Done

- Analyzer and focused tests above are green, with output kept to the final five lines while preserving exit status.
- Owning documentation and the tester skill reference describe the new commands; no new policy rule is added to the
  skill.
- `graphify update .` is run after the code changes.
- The change lands as one focused pull request against `main`; live acceptance runs on the coordinator's runtime,
  never from this task.

## Current status

Implementation complete; verification and delivery tracked in the pull request.
