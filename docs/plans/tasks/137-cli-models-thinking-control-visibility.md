---
title: "Task 137: CLI Thinking-Control Visibility in `sanad models`"
description: "Expose the resolved per-route thinking capability (status, options, default, and authority source) through `sanad models` so a developer or agent can read real thinking levels without opening the state database."
status: "done"
current_gate: "G4"
priority: "medium"
depends_on: "main @ 76b24771"
file_budget: 6
---

# Task 137: CLI Thinking-Control Visibility in `sanad models`

## 1. Problem & Live Evidence

Source: a live investigation on 2026-10-23 that needed the thinking levels of the
`deepseek-v4.1-flash` model on `opencode-go`, and of the same model published by the `HIVE`
custom provider as `deepseek-ai/deepseek-v4.1-flash-1017`.

- The daemon resolved a full capability descriptor per route and persisted it inside
  `provider_model_cache.models_json` (`thinking_control`: `status`, `kind`, `options[]`,
  `default_option_id`, `default_source`, `capability_revision`, `source`).
- `sanad models list --json` reported only `value`, `label`, `supports_reasoning`, and
  `is_default`, so `thinking_control` was silently dropped (`_ModelEntry` did not carry it).
- The human block printed a single `[reasoning]` Boolean badge, which cannot distinguish
  `supported` with four levels from `unknown` with none. On the HIVE route the badge was
  absent while the identical model on OpenCode Go carried levels, and the CLI gave no way
  to see that difference.
- `--thinking-mode`'s help text advertised the global vocabulary
  (`off, on, none, minimal, low, medium, high, xhigh, max, fast, balanced, normal, deep`)
  instead of the levels the selected route actually admits.
- No CLI command refreshes capabilities or inspects one model, so the only remaining
  authority was the SQLite cache, i.e. reading `state.db` by hand.

Consequence: the documented capability contract (`docs/technical/provider_protocol.md`
§2.3) was observable through the Client snapshot and the database, but not through the
Agent CLI that owns model inspection.

## 2. Locked Decisions

- Scope is read-only reporting. No part of the five-layer authority order changes, and the
  command still never refreshes the catalog and never contacts a provider.
- `sanad.models.v1` stays the document schema name. `thinking_control` is an **additive**
  optional member of each model entry, emitted only when the cached row carries a
  descriptor, so an older consumer that ignores unknown members keeps working and a model
  without a descriptor produces byte-identical output to today.
- The emitted descriptor is the stored one, serialized through
  `ThinkingControlDescriptor.toMap()` (the same shape the Client snapshot uses) rather than
  a CLI-private re-projection.
- The human block gains a `thinking:` segment listing the resolved option ids and marking
  the off option and the known default. It is omitted entirely when there is no descriptor,
  keeping today's lines unchanged.
- `--model` stays an exact-id filter (case-insensitive) and now also accepts a single model
  inspection: when the filter selects exactly one cached model, the human block additionally
  prints the authority `source`, `default_source`, and `capability_revision`.
- No new options, no new subcommands, no database or DTO schema change, and no change to
  `--provider`/`--model` exit codes.

## 3. Gates

### G0 — Discovery (closed)
- [x] Confirm `_ModelEntry` drops `thinking_control` and the human block prints one Boolean.
- [x] Confirm the cached row already carries the full descriptor per route.
- [x] Confirm `sanad.models.v1` is documented and covered by
      `agent/test/cli/models_command_test.dart`.

### G1 — Machine output
- [x] Carry `thinkingControl` on `_ModelEntry` from the cached raw entry.
- [x] Emit it through `toMap()` under `thinking_control` only when present.
- [x] Keep every existing key and its order unchanged.

### G2 — Human output
- [x] Print a `thinking:` summary of resolved option ids, marking `off` and the known default.
- [x] Print `unsupported`/`unknown` honestly instead of an empty level list.
- [x] Add the authority detail lines only for a single-model inspection.

### G3 — Regression coverage
- [x] Extend `agent/test/cli/models_command_test.dart` with a supported descriptor, an
      unsupported/unknown descriptor, and a model without a descriptor.
- [x] Assert the additive JSON contract: absent when the cache has no descriptor.
- [x] Assert the human summary text and the single-model authority lines.

### G4 — Documentation
- [x] Update `docs/technical/sanad_cli_architecture.md` §12 with the new members.
- [x] Record the change in `agent/CHANGELOG.md`.

### G5 — Delivery
- [x] `fvm dart analyze` clean in `agent/`.
- [x] Focused suite green.
- [x] Live verification against the running daemon on the primary Home.
- [x] Pull request opened without merging.

## 4. Acceptance Criteria

- [x] Given a cached model whose descriptor is `supported` with options
      `off/low/high/max` and default `max`, when `sanad models --model <id> --json` runs,
      then the entry carries `thinking_control` with that status, those option ids, and
      `default_option_id: max`.
- [x] Given a cached model with no descriptor, when the same command runs, then the entry
      has no `thinking_control` member and the rest of the document is unchanged.
- [x] Given a descriptor with `status: unknown`, when the human block is printed, then it
      reports the unknown state and invents no level list.
- [x] Given a single-model inspection, when the human block is printed, then the authority
      `source`, `default_source`, and `capability_revision` are shown.
- [x] Analyzer is clean for `agent/` and `agent/test/cli/models_command_test.dart` passes.

## 5. Definition of Done

- [x] `fvm dart analyze` clean in `agent/`.
- [x] `fvm dart test test/cli/models_command_test.dart` green.
- [x] Owning CLI documentation and `agent/CHANGELOG.md` updated.
- [x] Live evidence captured on the primary Home with scalar output only.
- [x] No secrets, no hardcoded ports, no absolute paths in tracked files.
