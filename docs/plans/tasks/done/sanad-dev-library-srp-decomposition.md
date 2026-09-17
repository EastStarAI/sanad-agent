---
title: "sanad-dev Library Responsibility Decomposition"
description: "Split oversized sanad-dev library and test files into cohesive modules without changing runtime behavior, ownership safety, or command compatibility."
status: completed
current_gate: G8
remaining_estimate: 0%
baseline_commit: 8798b7b
---

# sanad-dev Library Responsibility Decomposition

## Goal

Refactor `scripts/sanad_dev/` so each production and test file owns one cohesive responsibility, the CLI entry remains a thin composition/dispatch boundary, and no oversized mixed-concern file remains, while preserving every command, output contract, runtime ownership invariant, and cross-platform behavior.

## Motivation and Current Inventory

The standalone package currently compiles several large `part` files into one library. The shared-library model has allowed unrelated concerns and private helpers to accumulate together:

| File | Current size | Mixed responsibilities |
|---|---:|---|
| `scripts/sanad_dev/lib/runtime_commands.dart` | 2,109 lines | runtime state projection, ownership assessment, background launch, run orchestration, status, component control, stop, doctor, orphan cleanup, takeover, health waits |
| `scripts/sanad_dev/lib/switch_commands.dart` | 1,400 lines | switch admission, source-state assessment, process shutdown, client launch profiles, complete switch transaction controller |
| `scripts/sanad_dev/lib/developer_actions.dart` | 1,130 lines | journal reading/following, Client attach actions, Agent logs/restart, DevTools, UI driver forwarding |
| `scripts/sanad_dev/lib/instance_discovery.dart` | 759 lines | OS process snapshots, Flutter/DDS correlation, Agent probing, active-Home inference, instance selection |
| `scripts/sanad_dev/lib/cli.dart` | 449 lines | argument parsing, validation, dispatch, help rendering, runtime-selection helpers |
| `scripts/sanad_dev/test/sanad_dev_process_state_test.dart` | 912 lines | active Home, process selection, ownership, doctor/stop safety, client identity, journal selection, UI selection |

This task is a structural refactor, not a feature rewrite. Moving arbitrary line ranges into generically named files is insufficient: every resulting module must have a clear owner and stable dependency direction.

## Locked Decisions and Scope

- Work only in the existing `feature/sanad-dev-active-home` worktree and continue from baseline commit `8798b7b`.
- Preserve `scripts/sanad_dev/lib/sanad_dev_cli.dart` as the package composition root and compatibility export surface.
- The implementation may retain Dart `part` files where shared private access is genuinely useful, but concern boundaries must be explicit and circular feature ownership must not be introduced.
- Prefer small typed collaborators and shared helpers over duplicated code or file-global state.
- Preserve public and test-visible function/class names unless a compatibility forwarding declaration is required.
- Preserve all CLI command names, options, defaults, exit codes, help semantics, safety refusals, bounded waits, stdout/stderr routing, and ownership checks.
- Preserve the active-Home behavior from baseline commit `8798b7b`: only `run` selects a non-default Home; later workspace-scoped commands infer it; explicit `--home` remains authoritative.
- Preserve the launcher lease, launcher id, runtime nonce, workspace hash, Agent health, Client launch-profile, and exact PID/VM inventory checks. A refactor must never weaken mutation authority.
- Preserve cross-platform POSIX/Windows process discovery, command quoting, bootstrap, and secure runtime-file behavior.
- Do not invoke `sanad-dev switch`; this refactor does not authorize runtime source handoff.
- Do not add dependencies, change product behavior, redesign command output, or opportunistically fix unrelated defects. Record unrelated findings separately.
- Organize production modules under domain-owned `lib/src/` directories and organize tests under matching domain directories; do not leave the decomposed files as one flat `lib/` or `test/` list.
- Keep root-level `lib/` files only when they are intentional public entry points or thin compatibility forwarders for existing direct imports.
- Add nested `AGENTS.md` contracts under production `lib/` domains only. Do not add any `AGENTS.md` under `scripts/sanad_dev/test/`.
- Do not commit or push the SRP implementation without fresh user authorization.

## Target Module Boundaries

The executor may improve names while implementing, but the final ownership must be equivalent to the following map.

### CLI boundary

- `cli.dart`: minimal entry function and top-level dispatch only.
- A focused parser/options module: parse arguments into one typed command request and perform usage validation.
- A help/usage module: render command and option help without runtime mutation.
- A runtime-selection helper: explicit/inferred Home and recorded endpoint selection shared by command dispatch.

### Runtime discovery and identity

- Process discovery: OS snapshots, Flutter runner/DDS correlation, and process argument extraction.
- Agent discovery: Local Gateway credential candidates, authenticated health probing, and active-Home candidate resolution.
- Instance selection: exact Agent/Client selection, ambiguity results, and diagnostic selectors.
- Runtime state/ownership projection: `RuntimeProcessState`, client classification, active Home projection, and managed-ownership assessment.

### Runtime lifecycle commands

- Background launch command and managed-state handshake.
- Foreground/component run orchestration and readiness.
- Status projection only.
- Managed component request/stop orchestration.
- Doctor and stale-record repair.
- Target-orphan cleanup.
- Manual-runtime takeover and restoration.

### Developer actions

- Managed journal read/follow and interactive journal controls.
- Client reload/restart/attach and DevTools actions.
- Agent logs/restart actions.
- UI-driver command forwarding and exact driver selection.

### Runtime source switch

- Switch command admission and target-source assessment.
- Process/resource shutdown and availability waits.
- Switchable runtime transaction controller, target launch, rollback, and terminal-result persistence.

### Tests

Split `sanad_dev_process_state_test.dart` by behavior, not line count. At minimum create focused suites for:

- active-Home and credential-candidate discovery;
- Agent/Client process selection and ambiguity;
- runtime ownership and launch-profile validation;
- doctor, stop, and stale/orphan safety;
- managed journal and UI-driver selection.

Shared fake builders/fixtures must move to narrowly named test helpers rather than being copied between suites.

## Target Directory and Contract Layout

The final tree should follow this domain shape. Small deviations require an architectural reason recorded in this task.

```text
scripts/sanad_dev/
├── AGENTS.md
├── lib/
│   ├── AGENTS.md
│   ├── sanad_dev_cli.dart
│   ├── <intentional public or compatibility entrypoints only>
│   └── src/
│       ├── cli/
│       │   └── AGENTS.md
│       ├── discovery/
│       │   └── AGENTS.md
│       ├── runtime/
│       │   ├── AGENTS.md
│       │   ├── ownership/
│       │   ├── lifecycle/
│       │   └── switch/
│       ├── developer/
│       │   └── AGENTS.md
│       └── infrastructure/
│           └── AGENTS.md
└── test/
    ├── cli/
    ├── discovery/
    ├── runtime/
    │   ├── ownership/
    │   ├── lifecycle/
    │   └── switch/
    ├── developer/
    ├── infrastructure/
    └── support/
```

Directory rules:

- Tests mirror production domains where practical, but `test/` contains no nested `AGENTS.md` files.
- `test/support/` owns only reusable fakes, fixtures, builders, and hermetic seams; it cannot own assertions or production behavior.
- Avoid directories containing one trivial file when the parent domain remains cohesive, and avoid generic buckets such as `utils/`, `common/`, or `misc/`.
- Existing direct package imports must keep compiling through retained public files or thin root-level export/forwarding shims.
- Use repository-relative references in every contract and document.

Nested contract rules:

- `scripts/sanad_dev/AGENTS.md` remains the package-wide law and must become more abstract where child contracts specialize it.
- `lib/AGENTS.md` owns production-wide dependency direction, compatibility surfaces, and composition-root laws.
- Domain contracts own only durable invariants specific to their nearest source subtree.
- Contracts must not duplicate the module map or implementation procedure; design belongs in technical documentation and execution steps belong in this task.
- Add every new contract to `docs/llms.txt` and remove any stale contract statements contradicted by the new ownership boundaries.

## Dependency Direction

1. Pure models/parsers/helpers must not depend on command handlers.
2. Discovery may depend on runtime context and secure credential/file primitives, but not on lifecycle command handlers.
3. Ownership assessment may consume discovered models, but discovery must not call ownership mutations.
4. Command handlers may compose discovery, ownership, journal, and process-control services.
5. CLI parsing and help must not probe Git, processes, ports, credentials, or runtime files.
6. `sanad_dev_cli.dart` composes modules; lower-level modules must not import the composition root.
7. Tests should import the narrowest production module practical; compatibility tests may continue importing `sanad_dev_cli.dart` where its aggregate surface is the subject.

## Size and Cohesion Guardrails

- No handwritten production Dart file under `scripts/sanad_dev/lib/` may exceed 700 lines after the refactor.
- No ordinary test file under `scripts/sanad_dev/test/` may exceed 700 lines; shared fixtures do not become a new dumping ground.
- `cli.dart` should be at most 250 lines and contain no process discovery, HTTP transport, journal storage, or lifecycle implementation.
- Every new file must have one sentence in the technical architecture documentation stating its owned concern.
- Do not satisfy the limits with numbered files, arbitrary slices, duplicated helpers, minified formatting, or oversized extension methods that preserve the same mixed ownership.

## Gates

### G0 — Baseline characterization and dependency map

- [x] Confirm the worktree is based on commit `8798b7b` and has no unrelated changes beyond this task file.
- [x] Record current line counts and list every top-level declaration in the five oversized production files.
- [x] Map callers/tests for each declaration before moving it.
- [x] Run and record the baseline analyzer, complete package suite, and wrapper help smoke.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G1 — Discovery and ownership decomposition

- [x] Separate OS/Flutter process discovery, Agent probing/Home inference, and instance selection.
- [x] Separate runtime-state classification and ownership assessment from lifecycle commands.
- [x] Preserve aggregate exports or forwarding declarations required by existing consumers.
- [x] Split and pass focused discovery/ownership tests.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G2 — Lifecycle command decomposition

- [x] Extract background launch and managed handshake.
- [x] Extract run/readiness orchestration.
- [x] Extract status projection.
- [x] Extract managed component requests and stop.
- [x] Extract doctor, orphan cleanup, and manual takeover into distinct owners.
- [x] Keep shared wait/transport helpers in one narrowly named module rather than duplicating them.
- [x] Run focused lifecycle and ownership tests.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G3 — Developer-action decomposition

- [x] Separate journal streaming/control, Client actions, Agent actions, and UI-driver forwarding.
- [x] Preserve bounded log behavior, terminal key handling, attach identity validation, and nonzero failure statuses.
- [x] Run focused journal, attach, restart, and UI-selection tests.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G4 — Switch-controller decomposition

- [x] Separate switch admission/source assessment from process shutdown and transaction execution.
- [x] Separate the transaction controller from launch-profile/value objects where this reduces mixed ownership.
- [x] Preserve deferred tool-result, rollback, exact Client identity, and requester continuity semantics.
- [x] Run all source-switch and runtime-switch tests without invoking a live source handoff.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G5 — CLI routing and test-suite decomposition

- [x] Replace manual mixed parsing/dispatch state with a typed parsed-command boundary.
- [x] Keep no-argument/help behavior mutation-free and preserve all existing options and validation messages.
- [x] Split the oversized process-state test suite by behavior and deduplicate fixtures.
- [x] Enforce the size/cohesion guardrails with a deterministic test or repository script so future growth fails visibly.
- [x] Update technical architecture, QA documentation, `docs/llms.txt`, and the closest contract only where a durable law changed.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G6 — Domain directory organization

- [x] Move decomposed production modules from the flat `lib/` root into the agreed `lib/src/cli`, `lib/src/discovery`, `lib/src/runtime/{ownership,lifecycle,switch}`, `lib/src/developer`, and `lib/src/infrastructure` domains.
- [x] Keep only intentional public APIs, the composition root, and required compatibility forwarders at the `lib/` root.
- [x] Move tests into matching `test/cli`, `test/discovery`, `test/runtime/{ownership,lifecycle,switch}`, `test/developer`, and `test/infrastructure` domains.
- [x] Consolidate reusable test-only builders, fixtures, fakes, and seams under `test/support/` without moving assertions or production logic there.
- [x] Update Dart `part`, `part of`, import, export, wrapper, and test paths without changing the package API or runtime behavior.
- [x] Remove empty directories, stale flat files, obsolete forwarders, and generic dumping-ground paths after compatibility is proven.
- [x] Run analyzer, focused suites, complete package tests, and the wrapper help smoke after the path migration.
- [x] Record the final directory tree and any justified deviation from the target layout.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G7 — Nested production contracts

- [x] Retain `scripts/sanad_dev/AGENTS.md` as the abstract package-wide contract and remove details now owned by closer child contracts.
- [x] Add `scripts/sanad_dev/lib/AGENTS.md` for production-wide composition, dependency direction, and compatibility laws.
- [x] Add focused contracts under `lib/src/cli/`, `lib/src/discovery/`, `lib/src/runtime/`, `lib/src/developer/`, and `lib/src/infrastructure/`.
- [x] Keep each child contract concise, non-duplicative, and limited to durable laws for its subtree; keep design explanations in technical documentation.
- [x] Do not create any `AGENTS.md` inside `scripts/sanad_dev/test/`.
- [x] Update `docs/llms.txt` so every new contract is discoverable and remove stale contract references.
- [x] Verify every production Dart file is governed by the intended nearest contract and no contracts contradict each other.
- [x] Update `current_gate` and `remaining_estimate` when this gate closes.

### G8 — Complete verification and handoff

- [x] Run formatter and `fvm dart analyze` in `scripts/sanad_dev/`.
- [x] Run every focused suite touched during decomposition.
- [x] Run the complete `scripts/sanad_dev/` test suite with bounded output.
- [x] Run the worktree-local `scripts/sanad-dev -h` wrapper smoke and compare command/option coverage with baseline.
- [x] Run a dry-run for default and explicit custom Home selection without mutating another runtime.
- [x] If the user authorizes live verification, launch an isolated Agent/Client pair and verify status, bounded logs, reload/restart, UI discovery, stop, and post-stop logs; never invoke source switch.
- [x] Run `graphify update .`, `git diff --check`, recursive size checks, directory-layout checks, contract-discovery checks, and final diff review.
- [x] Mark all acceptance criteria only when evidence exists; update status and remaining estimate to zero only after the final gate closes.

## Acceptance Criteria

- [x] `sanad_dev_cli.dart` remains the stable composition/compatibility surface and existing importers compile unchanged.
- [x] All current commands, targets, options, aliases, defaults, help entries, validation messages, and exit statuses remain behaviorally compatible.
- [x] Active custom Home inference and explicit Home precedence remain covered and unchanged.
- [x] Managed mutation still requires the exact existing lease, process, Agent, Client, launcher-id, nonce, workspace, Home, endpoint, and inventory agreement.
- [x] No handwritten production file exceeds 700 lines; `cli.dart` does not exceed 250 lines; no ordinary test file exceeds 700 lines.
- [x] Every resulting production file has one cohesive owner matching the documented module map.
- [x] Production modules are organized under the agreed domain directories; root `lib/` contains only the composition root, intentional public APIs, and necessary thin compatibility files.
- [x] Tests mirror the production domains and shared fixtures live in `test/support/`; no `AGENTS.md` exists anywhere under `scripts/sanad_dev/test/`.
- [x] The package contract plus nested `lib/` contracts cover every production subtree without duplicated or contradictory laws, and all are indexed in `docs/llms.txt`.
- [x] No duplicated discovery, ownership, wait, process-control, journal, or argument-parsing implementation is introduced.
- [x] Existing focused and complete automated suites pass with no new skip, timeout, real hosted request, or shared-port serialization workaround.
- [x] Wrapper help and dry-run behavior match baseline on the current platform.
- [x] Cross-platform bootstrap/process tests continue passing on locally available coverage; CI-owned macOS/Linux/Windows coverage remains required before merge.
- [x] Documentation, QA matrix, task status, and Graphify are current.
- [x] Final diff contains structural changes and required documentation only—no unrelated feature or formatting churn.

## Definition of Done

- [x] Gates G0–G8 are closed with evidence in this file.
- [x] Analyzer, focused tests, complete package tests, wrapper smoke, size guard, and diff check pass.
- [x] Runtime ownership and security boundaries are unchanged and explicitly reviewed.
- [x] Relevant technical and QA documentation describes the final module ownership.
- [x] No live runtime outside the isolated worktree was stopped, restarted, switched, or otherwise mutated.
- [x] No commit or push was made without fresh user authorization.

## Final Verification Evidence

### Root facade audit

| Root library | Decision | Evidence |
|---|---|---|
| `scripts/sanad_dev/lib/sanad_dev_cli.dart` | Keep | Sole CLI composition root. |
| `scripts/sanad_dev/lib/runtime_context.dart` | Keep as a thin export | `client/test/interactive/inspect_ui.dart` is a tracked consumer outside the package. |
| Previous infrastructure/ownership/switch facades | Remove | Their only consumers were package-owned source or tests; both now import the narrow `lib/src/` owner directly. |

The recursive architecture guard proves the root allowlist, rejects package-internal imports through root facades, rejects test imports through compatibility facades, and rejects `AGENTS.md` files below `test/`.

### Final size snapshot

- Largest production file: `scripts/sanad_dev/lib/src/runtime/lifecycle/runtime_run.dart` at 653 lines.
- Largest ordinary test: `scripts/sanad_dev/test/infrastructure/sanad_dev_client_launch_profile_test.dart` at 668 lines.
- CLI dispatcher: `scripts/sanad_dev/lib/src/cli/cli.dart` at 219 lines.
- Root production Dart files: two (`sanad_dev_cli.dart` plus the proven `runtime_context.dart` facade).

### Automated and live evidence

- `fvm dart analyze`: no issues.
- Complete recursive package suite: 151 tests passed with one platform-owned skip and no new failure.
- Architecture/size guard: five checks passed.
- Worktree-local wrapper help smoke: passed with the baseline command surface.
- Default and explicit custom-Home dry runs: passed and selected their expected distinct Homes.
- Isolated post-refactor Agent/driver-enabled macOS Client cycle: launch, inferred-Home status, bounded Agent/Client logs, UI snapshot, Client reload/restart, safe Agent restart, complete stop, post-stop status, and retained Agent/Client journals all passed without source handoff.
- `git diff --check`: passed.
- `graphify update .`: completed after final code corrections.
- Technical architecture, QA matrix, nested production contracts, and `docs/llms.txt` contract discovery are current. Historical completed-task entries intentionally removed by the user from `docs/llms.txt` were not restored.
- No commit, push, or runtime source switch was performed.

## Executor Reporting Contract

At each gate closure, update this file with:

- completed checkboxes;
- current gate;
- remaining-work estimate;
- exact bounded verification results;
- any deviation from the target module map and its architectural reason.

On completion, report the final file-size table, exact test/analyzer results, live-verification scope if authorized, and `git status`. Do not claim completion from compilation alone.
