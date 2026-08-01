# Sanad Agent Repository Contract

Documentation is the core constraint of this project. Treat `/AGENTS.md` (this file) as the **Master Runtime Contract** and bootloader for AI agents and human developers working on the open-source components of the SanadAgent system.

> [!IMPORTANT]
>
> ### 🧭 Documentation is the most important part of this project
>
> Treat every `AGENTS.md` file as a **Runtime Contract**, not as optional notes. Poor documentation causes AI agent behavior drift, architecture drift, and incorrect changes in the wrong layers.
>
> 1. **Functional Discoverability:** For a complete, curated index of all codebase features, components, and guides, read **[docs/llms.txt](docs/llms.txt)** immediately.
> 2. **Operational Rules:** Plan, coordinate, and execute tasks using Git Worktrees, dynamic port offsets, and multi-agent systems.

---

## 1. Documentation Hierarchy

This repository uses a nested web of contracts. The closer the document is to the code, the more technical it should be:

* **`AGENTS.md`** (this file / repository root) — Main Master Contract governing all open-source components.
* **[client/AGENTS.md](client/AGENTS.md)** — Owns Flutter client UI contracts, widgets, and state registries (Flutter).
* **[agent/AGENTS.md](agent/AGENTS.md)** — Owns local Dart daemon interfaces, MCP servers, and background services (Dart).

### Rules for AI Agents and Developers

* **Always read the local `AGENTS.md`** file governing a subdirectory before making any edits in that directory.
* **Always update the relevant docs in the same session as the code change.** This is a strict Definition of Done (DoD).
* **Review the closest owning `AGENTS.md`** for every changed area. Update it only when the change alters a durable law, ownership boundary, invariant, or makes an existing statement stale; do not edit contracts merely to record implementation activity.
* **Keep higher-level docs abstract** where appropriate and push implementation detail down into local leaf docs.
* **Keep lower-level docs concrete, explicit, and practical.**
* **Remove stale or contradictory documentation immediately** to prevent behavior drift.
* **Use `README.md` only as the public product source of truth** for quick starts and pitches. **Do not let `README.md` become a competing implementation contract;** durable architecture and development contracts belong here in `AGENTS.md` and their nested child contracts.
* **Use `fvm` for all Flutter/Dart operations.** Never execute global flutter/dart commands.
* **All referenced file paths must be relative to the workspace root.**

---

## 1.1. The Strict Separation Pact

To prevent instruction drift and save session context, we enforce a strict separation between three knowledge streams in the repository:

1. **`AGENTS.md` files (The LAWS):** Core operational policies and rigid coding guidelines (e.g., "always use relative paths", "use fvm"). They MUST NOT contain design explanations or execution commands.
2. **Agent Skills in `.agents/skills/` (The TOOLS & SOPs):** Step-by-step developer/agent procedures and execution commands (e.g., worktree and testing workflows). They MUST NOT contain system design or database schemas.
3. **The `docs/` Directory (The DESIGN & GUIDANCE):** Technical design, product/UX specifications, APIs, schemas, operations, QA runbooks, and user/operator guidance. Docs MUST NOT establish coding/runtime laws for agents or duplicate developer-agent execution SOPs from skills. Commands are allowed only when necessary for user/operator, deployment, troubleshooting, or runbook content—not as instructions governing agent development behavior.

## 1.2. The Living Project Wiki & Incremental Documentation

The project documentation lives in the `docs/` directory under the 5-Pillar Architecture:

1. **`docs/product/`:** PRD, UX scenarios, wireframes.
2. **`docs/technical/`:** Database schemas, API specs, communication protocols.
3. **`docs/agent_engine/`:** Prompts, agent tools, function calling contracts.
4. **`docs/operations/`:** Deployment, n8n workflows, Docker configurations.
5. **`docs/qa_maintenance/`:** Test scripts, QA scenarios, troubleshooting guides (Runbooks).

* **Incremental Reverse Documentation:** Any task modifying or adding code to a file must include writing/updating the corresponding documentation page in `docs/` as part of its Definition of Done (DoD).

---

## 2. Directory Structure

The `sanad-agent` repository is structured as follows:

* **`agent/`**: Dart background daemon.
* **`client/`**: Flutter UI desktop client.
* **`docs/`**: Feature plans, product specifications, and markdown documentation.
* **`release/`**: The versioned release contract, generated-output policy, and shared Dart contract package under `release/contract/` for manifest, checksum, and Appcast models consumed by the agent, client, and release tooling.
* **`scripts/`**: Management, build, and release helper scripts.
  * `scripts/sanad_dev.dart` is the thin `sanad-dev` CLI entry point. Worktree runtime context, process supervision, instance discovery, and developer actions belong in focused modules under `scripts/sanad_dev/`; do not grow the entry point back into a monolith.

---

## 3. Global Project Rules

These rules apply strictly across the entire codebase and must be obeyed without exception:

* **Flutter Commands:** Always use `fvm` for version consistency & `fvm flutter analyze` for codebase diagnostics.
* **Code Quality & Organization (DRY):** Prioritize code reuse. Automatically refactor repeated logic into reusable helpers/classes.
* **Relative Paths Only:** Never use absolute paths in documentation, config files, or scripts. Always start from the workspace root (e.g., `agent/.env`).
* **Sequential Test Execution:** Use `--concurrency=1` or `concurrency: 1` only for E2E or integration tests that bind to system ports in `client` or `agent`, to prevent address collisions. Do not apply sequential execution to normal unit, widget, or fast test suites unless those specific tests bind shared ports or other exclusive system resources.
* **Clean & Focused Logging:** Keep server, local daemon, and UI client logs exceptionally clean. Log only key lifecycle transitions and critical events. Do not pollute standard output to save context tokens and prevent diagnostic noise.
* **Bounded Verification Output:** Analyzer and test commands must preserve their exit status while showing only the final 5 output lines by default (for example, `set -o pipefail; fvm dart test 2>&1 | tail -5`). Rerun only a failing command without the filter when full output is needed for diagnosis.
* **Pragmatic Implementations:** Keep implementations lean. Avoid boilerplate or overengineering unless strictly required for safety.
* **Agentic Engineering Principles:**
  * *Align Before You Build:* Align on code architecture and the plan in `docs/plans/tasks/` before writing code.
  * *Verifiable Goals:* Provide tasks with clear, automated, and testable DoD conditions.
  * *Design for Machines:* Structure documentation, files, and plans in semantic Markdown.
  * *Triage-First Ingest:* When importing code or system changes, perform a triage to identify potential contradictions with current documentation and report them first.

---

## 4. Standard Operating Procedures (SOPs)

### 4.1. Version Management (FVM)

Always use Flutter Version Management (FVM) for both the agent and client to ensure Dart and Flutter SDK consistency.

* In `client/`: `fvm flutter <command>`
* In `agent/`: `fvm dart <command>`

### 4.2. Verification & Code Quality

Choose verification by blast radius:

* Always run the relevant analyzer for code changes (`fvm flutter analyze` in `client/`, `fvm dart analyze` in `agent/`).
* Run the focused unit/widget test command that covers the changed behavior.
* Run the full fast suite only for broad or shared-surface changes.
* Run E2E/integration tests only when the change affects real daemon/client runtime integration, socket contracts, worktree runtime isolation, persistent runtime state, or another system boundary that mocks cannot validate.

---

## 5. UI Localization Constraint

* **No Arabic Text in the User Interface:** All interface text, labels, buttons, tooltips, and dialogs in `client/` must remain strictly in English.

---

## 6. Development Command Reference

### 6.1. Running the Project (Local Development)

Prefer `sanad-dev run` for normal local development because it launches a matched agent/client pair and keeps runtime ports, logs, and restart actions discoverable. Use direct `agent/` and `client/` commands only as a diagnostic fallback when debugging the launcher itself or a single process in isolation.

Manual fallback commands:

* **Start Agent Daemon:**

  ```bash
  cd agent && fvm dart run bin/sanad_agent.dart daemon
  ```

* **Start Flutter Client:**

  ```bash
  cd client && fvm flutter run --dart-define-from-file=config/prod.json -d macos
  ```

### 6.2. Runtime Control & Diagnostics (`sanad-dev`)

`sanad-dev` is the canonical development interface for running, observing, and debugging this project. Prefer it over hand-running separate daemon/client commands because it records the active runtime, selects the correct worktree instance, injects local gateway configuration, isolates mutable state, and exposes logs plus restart/reload actions for both sides of the app. Use `sanad-dev -h` to discover the current command set.

Core capabilities:

* Print available commands and options with `sanad-dev -h`.
* Start a matched agent/client runtime, optionally in driver mode for UI automation.
* Inspect runtime status and selected ports for the current worktree.
* Stream or tail client and agent logs.
* Hot restart or hot reload the Flutter client.
* Restart the agent daemon.
* Stop only the runtime owned by the current worktree.

High-signal commands:

* **Read Client Logs:** `sanad-dev logs client -n 50`
* **Read Agent Logs:** `sanad-dev logs agent -n 50`
* **Hot Restart Client:** `sanad-dev restart client`
* **Hot Reload Client:** `sanad-dev reload client`
* **Restart Agent Daemon:** `sanad-dev restart agent`

Agent tool calls must always use bounded log reads that terminate naturally. Agents must never invoke `sanad-dev logs ... -f` or `--follow`; those modes are reserved for a human-owned terminal outside agent tool execution because they block until interrupted and otherwise end only by timeout.

`sanad-dev` resolves the caller Git worktree before selecting a runtime. With multiple running instances, it automatically selects the instance matching the current worktree. Full runs isolate the daemon/VM ports and mutable daemon state automatically; explicit `-p <port>` remains a diagnostic override. If the recorded port from a previous run is no longer active but exactly one known instance exists, that instance is used automatically.

### 6.3. Worktree Runtime Boundary

- Linked-worktree `sanad-dev` runs use one worktree-scoped `SANAD_HOME` for identity, authentication, provider configuration, databases, memories, and runtime dumps; the primary checkout retains the normal Sanad Home. The explicit `sanad-dev switch --runtime current` handoff is the only exception: it moves one selected runtime group's source roots—one agent and every attached switch-capable client—while retaining the group's existing Home and endpoints, without affecting other runtimes.
- Agents must never invoke runtime source handoff autonomously. Execution requires a direct user instruction that explicitly requests the switch for the identified runtime and target worktree; development, testing, debugging, or general deployment requests are not authorization. Because every session and client sharing the selected runtime group is affected, disclose that impact and obtain fresh confirmation when other sessions may be active or ownership is uncertain.
- Every authorized source handoff must be bracketed by `sanad-dev status`: run it from the source worktree before `sanad-dev switch --runtime current`, then from the target worktree after the switch returns. Status is caller-worktree scoped and verifies the selected source, branch, agent, and clients; the original switch result remains authoritative for the handoff outcome.
* `SANAD_STATE_HOME` remains a supported test/external-daemon override but is not part of the `sanad-dev` worktree runtime model.
* The client local-daemon URL must come from `AppConfig.localGatewayUrl`; lifecycle probes and controls must not hardcode port `58085`.
* `sanad-dev` source runs use the Production client profile with local and cloud gateways enabled by default in every checkout type; the Dev profile is explicit internal integration only, and local-only verification uses the cloud-disable option.

---

## 7. Important Notes

* **Never** store secrets or API keys in code. Use environment variables.
* **No Hardcoded Magic Values**. Centrally manage constant values in configuration systems.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- For codebase questions, use one bounded Graphify operation first when graphify-out/graph.json exists. Prefer `path` or `explain` for known symbols and a small-budget `query` only to discover an unknown entry point. If traversal is broad, truncated, or dominated by generic symbols, stop expanding it and verify the surfaced files with direct source search.
- Treat Graphify as a navigation index, not the authority for runtime behavior. Source code and focused tests decide the final conclusion, and relevant node paths must belong to the intended repository corpus.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
