# Flutter VM Driver CLI Contract

## Scope

This contract governs `scripts/flutter_driver_cli/` and complements the repository-wide contract. The entry point at `scripts/flutter_driver_cli.dart`, the driver instrumentation at `client/lib/driver_main.dart`, and the `sanad-dev ui` adapter must remain compatible with this contract even though they are owned by their nearest directory contracts.

## Mission

Provide a deterministic, low-noise, development-only control surface through which AI agents and developers can inspect and interact with a driver-enabled Sanad Flutter Client on desktop, mobile, or web targets that expose a reachable Dart VM Service.

## Architecture Boundaries

- The standalone controller and CLI must not import `sanad_dev` runtime internals or infer Sanad runtime ownership.
- The standalone CLI accepts only an explicit VM Service endpoint or the documented environment endpoint. It must never select an arbitrary host process.
- Worktree/runtime discovery belongs exclusively to the `sanad-dev ui` adapter. Automatic selection must require exactly one launcher-owned Client for the invoking worktree; missing or ambiguous ownership fails closed.
- The target Client must register Flutter Driver and the Sanad service extensions through the driver entry point. The CLI must not claim control over arbitrary non-instrumented Flutter applications.
- VM Service transport is separate from the Local Gateway. Local Gateway credentials must never be sent to, stored by, or logged through this tool.

## Selector and Action Safety

- Keys are exact identities. A key selector must never degrade to substring matching.
- Missing scopes and out-of-range indexes fail explicitly. Scoped, indexed, and coordinate actions must never fall back to an unscoped target.
- The controller selects an isolate by the required advertised extension rather than assuming that the first isolate is the Flutter UI isolate.
- An action result describes only the action completed by the tool. Callers must verify the expected UI state separately; action responses must not claim an application outcome that was not observed.
- Batch execution stops on the first failed step unless the recipe explicitly opts into continuation.

## Output and Context Safety

- Machine mode emits exactly one parseable JSON value to standard output. Diagnostics may use standard error but must remain concise and must not include raw stack traces.
- Inspection output must remain filterable by scope and query and support compact, key-only, and interactive-only projections.
- Do not add duplicate framework wrappers, state-management internals, icon-font glyphs, or redundant text rows to snapshots.
- Consolidate useful tooltip and semantic metadata into the actionable keyed element.
- Never expose obscured text-field values. Successful text-entry results must not echo the entered value.
- Changes that can increase snapshot volume must add or preserve an explicit bounded-output strategy and truncation metadata; silent truncation is forbidden.

## Portability

- Host-side paths use platform-aware path handling; platform-specific separators must not be inferred from string suffixes.
- FVM owns Dart and Flutter execution. Windows child-process integration must preserve shell resolution for FVM wrappers.
- Mobile and web compatibility claims require the same driver instrumentation and a reachable explicit VM Service endpoint; desktop worktree discovery must not be generalized into unsupported remote discovery.

## Verification and Documentation

- CLI parsing, model serialization, failure-before-connection behavior, and output-safety invariants require focused automated tests.
- Changes to VM extensions or interactive actions require live verification against a driver-enabled Client when static tests cannot establish behavior.
- Live action verification must include a follow-up inspection that proves the expected UI state.
- Generated screenshots and other runtime evidence are not source artifacts and must remain untracked.
- Update the owning technical specification, QA matrix, tester skill, and task plan whenever the public command surface or runtime behavior changes.
