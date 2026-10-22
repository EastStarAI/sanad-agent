---
title: "Task 136: CLI Model Catalog Filtering & One-Shot Stdin Safety"
description: "Make `sanad models` honor --provider/--model/--json instead of silently printing every provider, add an additive --no-stdin opt-out for `sanad run` so shell loops cannot lose their input, and prove the already-landed blocked fail-fast live."
status: "in_review"
current_gate: "closed"
priority: "high"
depends_on: "main @ 4767a923"
file_budget: 8
---

# Task 136: CLI Model Catalog Filtering & One-Shot Stdin Safety

## 1. Problem & Live Evidence

Source of evidence: a live sweep of the **OpenCode Go** provider on 2026-10-22. 35 models
from `provider_model_cache (source=live)` were each exercised in **one new conversation per
model**, daemon-hosted (never `--standalone`), with `--execution-root` only (no workspace),
no tool permission, and a 90s cap. Result: 29 responses, 6 provider-level rejections.

### F1 — `sanad models --provider <id>` silently ignores the filter (open)

- `agent/lib/cli/runner/commands/models_command.dart#execute` never reads the `provider`,
  `model`, or `json` options. It always iterates `ProviderInstanceRepository.findAll()`
  (`ORDER BY created_at DESC`) and prints **every** configured instance.
- Reproduced at `4767a923`: `sanad models --provider opencode-go` prints four provider
  blocks in the order `Moonshot (kimi)`, `OpenCode Go (opencode-go) [DEFAULT]`,
  `ChatGPT co (openai-codex)`, `Z.AI Coding Plan (zai-coding)`.
- This is how a wrong catalog was reported: Z.AI is the last block, so `tail -5` of that
  output returns `glm-5`/`glm-5.2`/`glm-5.3`/`glm-5.3-flash`/`glm-5.3-flashx` — Z.AI models
  shown as if they were OpenCode Go models.
- `--json` is equally ignored (plain text is still printed), so no machine consumer can
  select a provider either.
- The option is accepted because `addCommonOptions` registers it globally; the value is
  then dropped. Silent acceptance is what makes the catalog untrustworthy.

### F2 — `sanad run` drains non-terminal stdin unconditionally (open)

- `OneshotRunner.run` reads `pipedContent = await stdinReader()` unconditionally; the
  default reader returns `null` only when `stdin.hasTerminal` is true.
- Live consequence: a driver loop of the form
  `while read -r model; do sanad run ... "$PROMPT"; done < models.txt`
  was consumed by the **first** `sanad run` invocation; the loop ended after one iteration
  and the remaining 34 models were never dispatched.
- Splicing piped content into the prompt is a documented workflow
  (`cat file | sanad run "prompt"`), so the behavior must stay available. What is missing is
  an explicit opt-out for callers whose stdin belongs to something else.

### F3 — Blocked provider rejections reported as `timeout` (already fixed upstream)

- Observed during the sweep: all six rejected models produced
  `status: timeout`, `exit_code: 124`, `error: "Turn execution timed out after Ns"`, with the
  real provider message buried only in `events.jsonl`.
- Root cause was **not** current main: the sweep ran a pre-`4767a923` AOT binary
  (a locally compiled AOT binary, built before `main` fast-forwarded during the session). At
  `4767a923`, `CliRuntimeNoticeEvent.isBlocked` (Task 125) already ends a one-shot run at
  once, and the rebuilt binary proves it: same prompt/model now returns in **0.89s** with
  `status: failed`, `cause: blocked`, `exit_code: 1`, and the provider message preserved in
  `error`.
- Action: **no code change**. Add a regression assertion that the provider message survives
  into `error`, and prove it live.

### Provider-level rejections recorded for re-verification (not code defects)

| Model | Provider message | Classification |
| --- | --- | --- |
| `mimo-v2.5-pro` | `Upstream request failed: [400] Unsupported model mimo-v2.5-pro` | Catalog drift: advertised but rejected |
| `muse-spark-1.2-contributor` | `This Go model trains on request data. Allow paid endpoints that train on request data in your workspace's Privacy settings to use it.` | Account privacy setting |
| `muse-spark-1.3-contributor` | same | Account privacy setting |
| `gemini-4-argon-contributor` | same | Account privacy setting |
| `longcat-2.0` | `OpenCode Go Insufficient credits: This OpenCode Go account has insufficient credits or quota.` + `Upstream request failed: Endpoint is unavailable.` | Billing/quota (`cause=provider_quota`) |
| `grok-4.6` | `Model does not support this protocol.` (`ModelProtocolUnsupported`) | Wire-protocol mismatch |

## 2. Locked Decisions

- Provider selector resolution order: exact instance UUID → exact `templateId` → display
  name compared case-insensitively with internal whitespace collapsed. First match wins;
  multiple matches are an error, not a guess.
- An unknown or ambiguous selector exits `2` (usage) with one actionable `stderr` line that
  lists the accepted selectors for the current Home. It must never silently fall back to
  "all providers".
- `--model` filters **within** the selected provider only (exact id, then case-insensitive
  exact). It never widens the selection.
- `--json` emits exactly one JSON object and no human text on `stdout`.
- Human text output keeps today's block format; `--quiet` suppresses the leading header only.
- `--no-stdin` is additive and default-off, so `cat file | sanad run "prompt"` is unchanged.
- Blocked/turn-completion semantics are out of scope for modification; F3 is verification only.
- No database/DTO/schema changes; no new dependencies.

## 3. Gates

### G0 — Discovery (closed)
- [x] Reproduce the unfiltered `sanad models` output at `4767a923` and capture block order.
- [x] Confirm `models_command.dart` contains no `provider`/`model`/`json` read.
- [x] Confirm `OneshotRunner` reads stdin unconditionally.
- [x] Separate stale-binary artifacts (F3) from open defects.

### G1 — Catalog filtering implementation
- [x] Add a shared selector resolver (instance id / template id / display name) usable by
      `models`, with a unit-testable pure matching function.
- [x] Apply `--provider` and `--model` in `ModelsCommand.execute()`.
- [x] Emit a single JSON document under `--json`.
- [x] Return `2` with one actionable line for unknown/ambiguous selectors.
- [x] Keep unfiltered output unchanged for existing callers.

### G2 — One-shot stdin opt-out
- [x] Add `--no-stdin` to `run` (default off) and thread it through `OneshotRunner`.
- [x] Prove the loop-safe invocation in an automated test.
- [x] Keep the documented piped-prompt workflow intact.

### G3 — Regression coverage
- [x] `agent/test/cli/models_command_test.dart` covering filter paths, JSON, and selector errors.
- [x] `run_command_test.dart` coverage for `--no-stdin` plus the pipe workflow.
- [x] Assert the blocked path keeps the provider message in `error` (F3 guard).

### G4 — Documentation
- [x] Update the owning CLI documentation with selector semantics and `--no-stdin`.
- [x] Record live evidence (scalar metrics only; no prompt or completion bodies).

### G5 — Live verification
- [x] Run the fixed CLI against the matched daemon and show a single-provider catalog.
- [x] Re-run a rejected model and show fail-fast with the provider message preserved.
- [x] Re-run a loop of two models and show both are dispatched with `--no-stdin`.

#### Live evidence (worktree build, daemon-hosted, primary Home, scalar metrics only)

| Check | Result |
| --- | --- |
| `models --provider opencode-go` | 1 provider block, 35 models, exit 0 |
| `models --provider "  opencode   go "` | same single block (display-name tier) |
| `models --provider nope` | exit 2, empty stdout, accepted selectors on stderr |
| `models --provider opencode-go --json` | `sanad.models.v1`, 1 provider, 35 models, default flagged |
| `models --provider opencode-go --model kimi-k3` | 1 model row |
| `models --provider opencode-go --model gpt-5.4` | exit 2 (foreign model) |
| `models --model glm-5.3` (no provider) | both serving providers reported |
| loop of 2 models **with** `--no-stdin` | 2/2 dispatched, both exit 0 |
| same loop **without** `--no-stdin` | 1/2 dispatched (pre-fix behavior reproduced) |
| `run -m grok-4.6` (provider rejection) | 911 ms, exit 1, `status=failed`, `cause=blocked`, provider text retained in `error` |
| `test/cli` suite (`--concurrency=1`) | 364 tests passed |
| `fvm dart analyze` (agent) | no issues |


## 4. Acceptance Criteria

- [x] Given two configured providers, when `sanad models --provider <templateId>` runs, then
      only that provider block is printed, exit code is `0`, and every emitted model belongs
      to that instance.
- [x] Given `--provider <uuid>` and `--provider "<Display Name>"`, when the same filter is
      applied, then the selected instance is identical.
- [x] Given an unknown selector, when `sanad models --provider nope` runs, then exit code is
      `2`, `stdout` contains no provider block, and `stderr` names the accepted selectors.
- [x] Given `--json`, when `sanad models --provider opencode-go --json` runs, then `stdout`
      parses as one JSON object whose `providers` array has exactly one entry.
- [x] Given `--model <id>` combined with `--provider`, when the model belongs to another
      provider, then it is not reported and the command fails with a usage error.
- [x] Given a `while read` loop over N models with `--no-stdin`, when each iteration runs,
      then all N turns are dispatched.
- [x] Given a blocked provider rejection, when `sanad run` completes, then `status` is
      `failed`, `cause` is `blocked`, exit code is `1`, and `error` retains the provider text.
- [x] Analyzer is clean for `agent/` and the focused suites pass.

## 5. Definition of Done

- [x] `fvm dart analyze` clean in `agent/`.
- [x] `fvm dart test test/cli/models_command_test.dart test/cli/run_command_test.dart` green.
- [x] Documentation updated in the owning CLI page (see G4).
- [x] Live verification evidence captured with scalar metrics only.
- [x] Diff stays inside the file budget and contains no secrets, no hardcoded ports, and no
      absolute paths in tracked files.
