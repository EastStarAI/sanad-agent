---
name: Sanad Agentic Developer
description: Standard operating procedures for live and isolated Sanad development, sanad-dev runtime control, diagnostics, verification, Git worktrees, and Pull Request delivery.
---

# Sanad Agentic Developer Protocol

Use this protocol to choose the correct development boundary, modify Sanad, verify the result, control the active runtime, and deliver reviewable changes.

## 1. Choose the Development Mode

### A. Live Current-Checkout Development

Use the currently running source checkout when the requested change is focused, the user wants the active Sanad instance updated in place, no parallel branch isolation is required, and focused verification can prove that the daemon will start again.

The active daemon can safely participate in its own source update:

1. Confirm that `sanad-dev status` selects the runtime for the current checkout.
2. Inspect the owning contracts and source before editing.
3. Make the focused source and documentation changes in the current checkout.
4. Run the required analyzer and focused tests before restarting anything.
5. Review the diff and keep a known rollback path. Do not live-restart a risky bootstrap, dependency-injection, database-migration, or supervisor change unless startup/recovery coverage passes; use isolated mode instead when failure could strand the active agent.
6. Inspect a bounded pre-restart log window:

   ```bash
   sanad-dev logs agent -n 100
   ```

   Agent tool calls must use bounded log reads that terminate naturally. Never invoke `sanad-dev logs` with `-f` or `--follow`: follow mode blocks until interrupted, returns to the tool only by timeout, and can prevent the controlled-restart checkpoint from becoming safe. Continuous following is reserved for a human-owned terminal outside agent tool execution.
7. Request the controlled restart:

   ```bash
   sanad-dev restart agent --timeout 60
   ```

   The default timeout is 60 seconds. The daemon drains every active session before returning its single success response. For a tool-origin request, `sanad-dev` forwards the requester session/tool-call identity; after the response, the coordinator waits for that exact `shell_execute` result to persist in an `after_tool_result` checkpoint before the child exits. A timeout without `--force` returns failure and leaves the daemon running. Never replace a rejected safe restart with a process kill.

   When invoking this command through `shell_execute`, set the tool's own `timeout_ms` above the restart timeout plus transport overhead (for example, at least 70000 for `--timeout 60`) so the wrapper does not cancel the request just before the daemon responds.
8. Startup recovery reclaims the same durable turn under the updated source. After the turn reconnects, check status and bounded logs, then repeat the focused behavioral verification:

   ```bash
   sanad-dev status
   sanad-dev logs agent -n 100
   ```

9. For client-only source changes, keep the daemon running and use `sanad-dev reload client` or `sanad-dev restart client` according to the changed Flutter state boundary.

### Same-Turn Self-Repair Loop

Live mode supports more than deploying a completed patch. The recovered turn loads the updated runtime catalog and tool implementations, so it can continue an iterative repair loop against the same checkout:

1. Capture the failing tool result or bounded logs.
2. Read the owning source and contracts, then make the smallest repair.
3. Analyze and run focused tests before applying the change.
4. Request `sanad-dev restart agent --timeout 60` with `shell_execute.timeout_ms: 70000` or higher; let the restart tool result reach its durable checkpoint.
5. Continue in the restored turn, retry the repaired tool, and verify its real result.

For a stubborn runtime bug, add one temporary structured log flag, analyze/test, restart through the same checkpoint-safe path, reproduce the behavior, and read a bounded post-restart log window. Fix the first violated ownership boundary, add regression coverage, remove the temporary logs, and restart/verify again in the same durable turn.

This loop depends on the daemon returning successfully. If the modified bootstrap, supervisor, dependency graph, database migration, or recovery path could prevent startup or turn restoration, use isolated worktree mode instead.

### B. Isolated Worktree Development

Use an isolated Git worktree for parallel work, broad or risky changes, PR-bound tasks, experiments, migrations, supervisor/bootstrap changes, or any task where the active runtime must remain available as the developer while another copy is tested.

- Worktree path convention: `.agent/worktrees/<plan_id>-<branch_name>`.
- Create and enter the worktree before editing or testing:

  ```bash
  git worktree add .agent/worktrees/<plan_id>-<branch_name> <branch_name>
  ```

- Run `sanad-dev` from that worktree. It detects the caller through Git, allocates daemon and VM-service ports, injects the selected local gateway URL, creates one worktree-scoped `SANAD_HOME` for identity, credentials, providers, databases, memories, dumps, and runtime state, and isolates client preferences with the same home-derived boundary.
- Do not set `SANAD_STATE_HOME`, hand-assign ports, or edit tracked `.env`/JSON files for normal worktree runs. `sanad-dev` removes inherited `SANAD_STATE_HOME` from its worktree runtime environment.
- Remove the worktree after the branch is merged or abandoned:

  ```bash
  git worktree remove .agent/worktrees/<plan_id>-<branch_name>
  ```

## 2. Task Plan Contract

Before implementation, align the task in `docs/plans/tasks/` when the repository contract or task scope requires a tracked plan. Keep the plan machine-checkable and useful during execution rather than writing a narrative progress log.

Every task file must include:

1. **Goal:** one bounded statement of the user-visible or system outcome.
2. **Locked decisions and scope:** confirmed behavior, boundaries, and exclusions needed to prevent ambiguity.
3. **Execution gates:** ordered Markdown sections containing `- [ ]` checklist items. Each gate groups work that can be completed and reviewed together.
4. **Acceptance criteria:** explicit `- [ ]` checks describing observable, testable outcomes. Criteria may be global or attached to a gate, but they must be more precise than implementation activities.
5. **Definition of Done:** analyzer/tests, documentation, graph maintenance, live verification when requested, and delivery constraints relevant to the task.
6. **Current status:** frontmatter or a compact status section with the current gate and remaining-work estimate when the user requests progress tracking.

Use this minimal shape:

```markdown
## Goal
...

## Gates

### G0 — Discovery
- [ ] ...

### G1 — Implementation
- [ ] ...

## Acceptance Criteria
- [ ] Given ..., when ..., then ...
- [ ] Automated coverage proves ...

## Definition of Done
- [ ] ...
```

Update the current gate, completed checkboxes, and remaining estimate whenever a gate closes. A gate closes only when its acceptance evidence exists; writing code alone is not completion.

## 3. Runtime Control and Diagnostics (`sanad-dev`)

`sanad-dev` is the canonical interface for launching, selecting, observing, and controlling the matched Sanad agent/client runtime.

Discover the current command set:

```bash
sanad-dev -h
```

### Launch and Inspect

```bash
sanad-dev run
sanad-dev run --driver
sanad-dev run --background
sanad-dev run --background --driver --no-cloud
sanad-dev status
```

Local and cloud gateway connections are enabled by default. Use `--no-cloud` only for explicit local-only verification. `--cloud` is an explicit restatement of the default, not a requirement for normal connected development.

Use `--home user` only when a linked worktree intentionally needs the primary user's Sanad Home. Otherwise allow the launcher to choose the worktree-scoped home; an explicit custom home must be an absolute path.

`run --background` is the sole official detached launch mode. It starts one detached launcher that remains the owner of the Agent, Clients, journals, and complete process trees, then returns success only after a bounded handshake proves the requested components are managed. Never wrap `sanad-dev run` in user-composed `nohup`, `screen`, `script`, or shell-background recipes. A temporary or non-TTY shell must use `--background`; launcher interruption before managed must publish a staged failure and clean every process it spawned.

After any background launch or startup failure, use `sanad-dev status` as the canonical diagnostic. It distinguishes requested Home, resolved Home, startup stage, outcome, exit status, and bounded failure reason from current process/lease ownership. A fresh `starting` attempt is transitional diagnostic state only and never grants mutation authority.

### Logs and Runtime Actions

```bash
sanad-dev logs client -n 50
sanad-dev logs agent -n 50
sanad-dev restart client
sanad-dev reload client
sanad-dev restart agent --timeout 60
sanad-dev restart agent --timeout 60 --force
sanad-dev stop
```

Agent restart accepts `--timeout <seconds>` from 1 through 3600 and defaults to 60. `--force` does not skip the wait; it permits process exit only after the selected timeout expires and the single response is flushed. Use force only when the user explicitly accepts that executing non-idempotent tools may recover with unknown outcomes.

Client restart/reload reuses and validates the matched live Flutter process's launch profile. If it reports a missing profile, worktree mismatch, or gateway mismatch, stop and diagnose discovery; never bypass the guard with the primary VM port or a direct global `flutter attach`.

Always keep agent-issued log commands bounded. Do not add `-f` or `--follow`.

The launcher resolves the caller's Git worktree before selecting an instance. Use `-p <port>` only when an explicit diagnostic override is necessary. With concurrent worktree runtimes, issue `status`, logs, UI, restart, reload, and stop from the owning worktree; never select the newest global process or reuse another worktree's Agent/VM port. Restarting or stopping one proven managed group must leave every sibling worktree runtime unchanged.

### User-Authorized Runtime Source Handoff

`sanad-dev switch --runtime current` changes the source code used by the complete selected agent/client pair and therefore affects every session sharing it. An agent must never infer permission to run it from a request to develop, test, debug, verify, restart, or deploy a change.

Before invoking source handoff:

1. Require a direct user instruction that explicitly requests switching the identified runtime to the identified target worktree.
2. State that all sessions sharing that runtime pair will reconnect against the new source.
3. If another session may be active, the pair is ambiguous, or the target was not explicit, stop and obtain fresh user confirmation.
4. Use requester identity to select and recover the correct pair, but never treat that identity as evidence of consent.
5. From the source worktree, run `sanad-dev status` immediately before the handoff and record the selected runtime source, branch, agent, and clients.
6. From the target worktree, invoke `sanad-dev switch --runtime current`.
7. Treat the original switch tool result as authoritative: it returns `complete`, `rolled_back`, `failed`, or `recovery_failed` after startup recovery. Do not retry a failed or rolled-back switch without another direct user instruction.
8. After the switch tool returns and the session recovers, run `sanad-dev status` from the target worktree. Verify that the runtime source and branch match the target and that the expected agent and clients are running. Status is caller-worktree scoped and is required post-handoff verification, but it must not override or reinterpret the original switch result.

### Manual Runtime Overrides

Manual daemon/client commands are a diagnostic fallback only when debugging `sanad-dev` itself or one process in isolation. Preserve the current unified-home model: set one appropriate absolute `SANAD_HOME`, remove inherited `SANAD_STATE_HOME`, and pass ports inline without editing tracked configuration.

## 4. Flagged Lifecycle Tracing

Use this procedure when a disconnect, reconnect, restart, race, or device switch cannot be explained from static inspection or existing tests:

1. Choose one unique temporary flag, such as `Debug1`, for the investigation.
2. Add compact structured logs at each suspected ownership boundary. Log state identity, resource counts, lifecycle phase, and routing identity; never log secrets or full payloads.
3. Run the relevant analyzer, then apply the code with `sanad-dev restart client` or the safe `sanad-dev restart agent --timeout 60` flow.
4. Reproduce the exact user sequence.
5. Read bounded, flag-filtered windows from both processes when relevant:

   ```bash
   sanad-dev logs client -n 500 | grep 'Debug1'
   sanad-dev logs agent -n 500 | grep 'Debug1'
   ```

6. Increase the bounded window only when the transition falls outside it.
7. Find the first ownership boundary where the invariant changes and fix that owner rather than masking a downstream symptom.
8. Repeat the reproduction and confirm the bad transition is absent.
9. Convert the sequence into focused automated regression coverage.
10. Remove temporary logs and rerun analysis and tests.

## 5. Pull Request Delivery

For review-bound work:

1. Commit inside the owning checkout/worktree with a descriptive, plan-referenced message.
2. Push the branch to origin.
3. Create the PR with a problem/goal, technical changes, and exact verification results:

   ```bash
   gh pr create --title "<plan_id>: <short_description>" --body-file - <<EOF
   ## Problem / Goal
   Describe the issue or requested feature.

   ## Technical Changes
   List files modified and rationale.

   ## Verification
   Detail the tests run and results.
   EOF
   ```
