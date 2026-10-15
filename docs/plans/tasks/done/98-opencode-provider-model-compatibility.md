---
title: "Task 98: OpenCode Go Provider Model Compatibility and Sanad Delegation Architecture"
description: "OpenCode Go compatibility evidence plus daemon-backed session intervention, native sanad run delegation machine contract, and supervisor integration for safe delegated coding."
status: "completed"
current_gate: "G5 — Delegation Tool-Use Proof and Acceptance"
remaining_estimate: "15%"
priority: "high"
depends_on: "OpenCode Go provider profile; Provider Registry; Sanad CLI and local gateway session runtime; Task 43 reasoning runtime"
evidence_id: "98"
evidence_source: "Live sequential probe of 33 advertised OpenCode Go models via Sanad Agent CLI, plus 2026-09-22 Global-regions retest of the 4 affected models"
evidence_date: "2026-09-22"
---

# Task 98: OpenCode Go Model Compatibility & Sanad Delegation Architecture

## 1. Goal

Establish a verified OpenCode Go compatibility baseline and deliver safe autonomous coding delegation through Sanad: daemon-backed session inspection and intervention, native `sanad run` CLI delegation machine contract, and event-first `delegate-task-supervisor` integration, without leaking secrets, changing logical workspace ownership, or mutating unrelated runtimes.

> **Snapshot scope:** The compatibility matrix proves **one-shot, zero-tool provider/model response compatibility only** (transport success plus exact-instruction compliance). It does **not** prove tool-calling or autonomous coding for any model; that proof is deferred to gate G5. Model availability and behavior are a **dated current snapshot** (initial G0 batch plus the 2026-09-22 Global-regions retest), not a durable guarantee; OpenCode Go can add, remove, or re-route models at any time.

---

## 2. Locked Decisions and Scope

- **Investigation-First Constraint:** This task plan is based on direct empirical evidence gathered by invoking all 33 advertised models sequentially through Sanad CLI (`agent/bin/sanad_agent.dart run`) with zero mock data and zero synthetic assertions.
- **Pure-Dart CLI Routing:** Uses Sanad CLI attached to the active local daemon via WebSocket local gateway (`ws://127.0.0.1:<port>/gateway`). Does not use `--standalone`, does not take over runtime locks, and does not alter stored credentials or provider profiles.
- **Zero Secrets / Relative Paths:** All documentation, logs, and artifacts strictly avoid hardcoded machine paths, tokens, authorization headers, account identifiers, session UUIDs, or raw network trace headers.
- **Skill Topology Invariant:**
  - `sanad-delegate` (new skill) is an instruction-only skill teaching orchestrators how to drive the native `sanad run` machine contract with task brief intake, provider/model selection, workspace anchoring, execution timeouts, signal trapping, result artifact writing, session continuation, and explicit non-interactive tool approval boundaries.
  - `delegate-task-supervisor` is extended only to orchestrate `sanad` as a first-class implementer alongside `opencode` and `antigravity`, consuming its timeline and managing concurrency.
  - `sanad-agentic-developer` remains dedicated to developer operations: worktree management, `sanad-dev` lifecycle/restart/logs, and test verification; it does not duplicate delegation mechanics.
- **Daemon-Backed Session Control:** Delegation requires real CLI `session list/show/stop` behavior, known session IDs, and daemon-authoritative pending-request state before delegation runs.
- **Clarification Safety:** `system_ask_user` is distinct from an ordinary gated-tool permission. `--allow-all-tools` must never answer it. A question remains pending until an explicit answer is submitted for the matching session and request.
- **Typed Intervention:** CLI inspection exposes `pending_permission_request`; separate commands answer a clarification or allow/deny a tool request. Both bind `session_id` and `request_id`, and stale, resolved, or mismatched requests fail closed.
- **Workspace Separation:** The conversation remains attached to the existing logical `sanad-agent` workspace. The execution worktree is a separate filesystem root. Delegation must not register, create, select, or switch a Sanad workspace.
- **Native Sanad CLI Delegation Contract:** Delegation execution is built directly into the native compiled `sanad run` CLI within the Agent, with `sanad-delegate` serving as the instruction-only skill for external orchestrators; it requires no skill-local runtime packages, scripts, or Node.js.
- **Matrix Proof Scope:** The compatibility matrix proves one-shot zero-tool response compatibility only. Tool-use and autonomous coding proof belong to the final verification gate.
- **Live Progress:** Full external structured streaming is optional. On-demand session inspection and event-first `needs_input` / `needs_permission` transitions are required. No terminal viewer is required because conversations already appear in the Client.
- **Terminal Result Contract:** The final `sanad run --json` envelope remains the terminal result contract, but it is insufficient by itself for pending-request discovery and intervention.
- **OpenCode-Delegate Repair:** `opencode-delegate` error-surfacing repair is deferred and low priority because `sanad-delegate` is intended to replace that path.
- **Supervisor Run Topology:** One supervisor run serves each reviewing orchestrator. It supports dynamic `add/enqueue`, explicit `close`, and one event-first `watch-once` surface across its tasks.
- **Interactive Runtime Dogfooding:** After G1–G3, agy drives a managed Agent/Client pair on the dedicated test Home and exercises the real Sanad CLI against OpenCode Go with `deepseek-v4-flash`. This complements rather than replaces automated coverage. The API key remains user-configured in the test Home and is never exposed to agy, CLI arguments, logs, briefs, or tracked artifacts.

---

## 3. Non-Goals

- Do not modify production source code, tests, or contracts during the investigation phase.
- Do not autonomously alter OpenCode workspace privacy or region settings.
- Do not add external SDKs or third-party wrappers (Hermes, OpenCode CLI, Python scripts) into Sanad Agent runtime.
- Do not alter the provider credential storage schema (`SecretStore`, `state.db`).

---

## 4. Empirical Model Compatibility Matrix

### 4.1. Probe Methodology
- **Command:** `fvm dart run bin/sanad_agent.dart run "Reply with exactly SANAD_MODEL_OK and nothing else." --provider "OpenCode Go" -m <model-id> --json --timeout 30`
- **Execution Mode:** Strictly sequential execution from `agent/`, attached to the active daemon local gateway, without `--allow-all-tools` (zero tool permission).
- **Date & Scope:** 33 models advertised live by Sanad's OpenCode Go provider discovery.
- **Snapshot Caveat:** These results are a dated snapshot (initial G0 batch plus the 2026-09-22 retest), not a durable guarantee of availability or behavior.
- **Global-Regions Retest (2026-09-22):** After the user manually enabled Global regions in their OpenCode workspace Privacy settings and explicitly authorized retesting, the four Category-2 models (`deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-flash`, `deepseek-v4.1-flash`) were re-probed sequentially with the identical command shape above. All four succeeded with exact `SANAD_MODEL_OK` responses. One transient rerun note: `deepseek-v4.1-flash` initially produced exit code 78 (`--standalone cannot use this Sanad Home while another runtime owns it`) from a momentary gateway health-probe collision; an immediate deterministic rerun with the same command succeeded (exit code 0, exact `SANAD_MODEL_OK`), confirming local-runtime noise rather than a provider defect. The `--standalone` flag was never passed; probes always attached to the existing runtime.

### 4.2. Complete Model Results Table

| # | Normalized Model ID | Display Name / Family | Status | Exit Code | Duration | Safe Category | Redacted Error Fingerprint | Reasoning Tokens |
|---|---|---|---|---|---|---|---|---|
| 1 | `kimi-k2.7-code` | Kimi K2.7 Code | **Compatible** | 0 | 21.1s | Success | None (`SANAD_MODEL_OK`) | 23 |
| 2 | `kimi-k2.6` | Kimi K2.6 | **Compatible** | 0 | 21.9s | Success | None (`SANAD_MODEL_OK`) | 38 |
| 3 | `glm-5.2` | GLM 5.2 | **Compatible** | 0 | 21.1s | Success | None (`SANAD_MODEL_OK`) | 33 |
| 4 | `glm-5.1` | GLM 5.1 | **Compatible** | 0 | 20.2s | Success | None (`SANAD_MODEL_OK`) | 0 |
| 5 | `mimo-v2.5-pro` | Mimo V2.5 Pro | **Compatible** | 0 | 22.2s | Success | None (`SANAD_MODEL_OK`) | 28 |
| 6 | `mimo-v2.5` | Mimo V2.5 | **Compatible** | 0 | 21.6s | Success | None (`SANAD_MODEL_OK`) | 44 |
| 7 | `minimax-m3` | Minimax M3 | **Compatible** | 0 | 19.8s | Success | None (`SANAD_MODEL_OK`) | 14 |
| 8 | `minimax-m2.7` | Minimax M2.7 | **Incompatible** | 1 | 19.5s | Endpoint Unavailable | `Upstream request failed: Endpoint is unavailable.` | — |
| 9 | `minimax-m2.5` | Minimax M2.5 | **Compatible** | 0 | 21.5s | Success | None (`SANAD_MODEL_OK`) | 39 |
| 10 | `deepseek-v4-pro` | DeepSeek V4 Pro | **Compatible** (retest 2026-09-22) | 0 | — | Success | None (`SANAD_MODEL_OK`) | 0 |
| 11 | `deepseek-v4-flash` | DeepSeek V4 Flash | **Compatible** (retest 2026-09-22) | 0 | — | Success | None (`SANAD_MODEL_OK`) | not reported |
| 12 | `qwen3.7-max` | Qwen 3.7 Max | **Compatible** | 0 | 20.8s | Success | None (`SANAD_MODEL_OK`) | 27 |
| 13 | `qwen3.7-plus` | Qwen 3.7 Plus | **Compatible** | 0 | 20.8s | Success | None (`SANAD_MODEL_OK`) | 28 |
| 14 | `qwen3.6-plus` | Qwen 3.6 Plus | **Compatible** | 0 | 22.7s | Success | None (`SANAD_MODEL_OK`) | 26 |
| 15 | `deepseek-v4-flash-vision-exp` | DeepSeek V4 Flash Vision | **Compatible** | 0 | 19.9s | Success | None (`SANAD_MODEL_OK`) | 0 |
| 16 | `deepseek-flash` | DeepSeek Flash | **Compatible** (retest 2026-09-22) | 0 | — | Success | None (`SANAD_MODEL_OK`) | 0 |
| 17 | `deepseek-v4.1-flash` | DeepSeek V4.1 Flash | **Compatible** (retest 2026-09-22) | 0 | — | Success | None (`SANAD_MODEL_OK`) | 0 |
| 18 | `glm-5.3` | GLM 5.3 | **Compatible** | 0 | 20.8s | Success | None (`SANAD_MODEL_OK`) | 0 |
| 19 | `grok-4.6` | Grok 4.6 | **Incompatible** | 1 | 19.2s | Endpoint Unavailable | `Upstream request failed: Endpoint is unavailable.` | — |
| 20 | `grok-4.7` | Grok 4.7 | **Incompatible** | 1 | 20.0s | Endpoint Unavailable | `Upstream request failed: Endpoint is unavailable.` (Rerun verified) | — |
| 21 | `muse-spark-1.2-contributor` | Muse Spark 1.2 Contributor | **Incompatible** | 1 | 20.5s | Privacy: Training Data | `Upstream request failed: This Go model trains on request data...` | — |
| 22 | `muse-spark-1.3-contributor` | Muse Spark 1.3 Contributor | **Incompatible** | 1 | 19.9s | Privacy: Training Data | `Upstream request failed: This Go model trains on request data...` | — |
| 23 | `glm-5.3-flash` | GLM 5.3 Flash | **Compatible** | 0 | 22.5s | Success | None (`SANAD_MODEL_OK`) | 0 |
| 24 | `omen-alpha` | Omen Alpha | **Compatible** | 0 | 21.1s | Success | None (`SANAD_MODEL_OK`) | 0 |
| 25 | `gpt-5.6-luna` | GPT 5.6 Luna | **Incompatible** | 1 | 20.0s | Endpoint Unavailable | `Upstream request failed: Endpoint is unavailable.` | — |
| 26 | `hy3` | HY3 | **Compatible** | 0 | 22.7s | Success | None (`SANAD_MODEL_OK`) | 19 |
| 27 | `hy4-preview` | HY4 Preview | **Compatible** | 0 | 22.9s | Success | None (`SANAD_MODEL_OK`) | 59 |
| 28 | `kimi-k3` | Kimi K3 (Default) | **Compatible** | 0 | 20.5s | Success | None (`SANAD_MODEL_OK`) | 0 |
| 29 | `mimo-v2.6-flash` | Mimo V2.6 Flash | **Compatible** | 0 | 20.5s | Success | None (`SANAD_MODEL_OK`) | 6 |
| 30 | `mimo-v2.6-pro` | Mimo V2.6 Pro | **Compatible** | 0 | 20.5s | Success | None (`SANAD_MODEL_OK`) | 19 |
| 31 | `longcat-2.0` | Longcat 2.0 | **Compatible** | 0 | 21.6s | Success | None (`SANAD_MODEL_OK`) | 19 |
| 32 | `qwen3.8-max` | Qwen 3.8 Max | **Compatible** | 0 | 21.3s | Success | None (`SANAD_MODEL_OK`) | 36 |
| 33 | `qwen3.8-flash` | Qwen 3.8 Flash | **Partial** | 0 | 22.2s | Instruction Noncompliance | None (returned readiness greeting `Ready. What would you like me to help with?` instead of exact `SANAD_MODEL_OK`) | 25 |

> Retest rows (10, 11, 16, 17) reflect the 2026-09-22 Global-regions retest envelopes; per-probe durations were not exposed by the `--json` envelope and are shown as `—` rather than estimated. `reasoning_tokens` values are as reported in each retest usage block ("not reported" means the envelope omitted the field).

---

## 5. Category Breakdown & Principal Causes

### 5.1. Summary Statistics

| Category | Model Count | Percentage | Operational Impact |
|---|---|---|---|
| **Category 1: Transport-Successful (one-shot, zero-tool)** | 27 | 81.8% | Immediately usable for zero-tool Sanad sessions. 26 of 27 returned exact `SANAD_MODEL_OK`; `qwen3.8-flash` is transport-successful but exact-instruction noncompliant (see 5.2.1a). Tool-use compatibility is unproven for all and is deferred to G5. |
| **Category 2: Privacy / Region Setting (Global Region Required)** | 0 | 0% | Resolved: all 4 affected models became transport-successful after the user enabled Global regions and authorized the 2026-09-22 retest (see 5.2.2). |
| **Category 3: Privacy / Training Data Setting (Training Allowed Required)** | 2 | 6.1% | Requires user to allow paid endpoints that train on data in OpenCode Privacy. Not tested; enabling remains out of scope. |
| **Category 4: Model-Specific Endpoint Unavailable** | 4 | 12.1% | Upstream OpenCode router has no backend route; model is non-functional. |
| **Total Models Advertised** | **33** | **100%** | Dated snapshot (2026-09-22), not a durable guarantee. |

### 5.2. Root Cause Analysis & Confidence

1. **Category 1: Transport-Successful (27 models) — High Confidence (zero-tool scope only)**
   - **Evidence:** HTTP 200 via `https://opencode.ai/zen/go/v1/chat/completions`; 26 of 27 returned exact `SANAD_MODEL_OK`.
   - **1a. Exact-Instruction Noncompliance (`qwen3.8-flash`):** Transport succeeded (exit code 0, HTTP 200, valid usage) but the model returned a conversational readiness greeting (`Ready. What would you like me to help with?`) instead of the exact `SANAD_MODEL_OK` string. This is instruction-following noncompliance, not a transport or privacy failure; the model is usable but demonstrated weaker exact-output discipline in this snapshot.
   - **Reasoning Capabilities:** In the initial G0 batch, 17 of the then-23 successful models returned non-zero `reasoning_tokens` (6–59 tokens), demonstrating compatibility with Sanad's thinking stream extraction. In the 2026-09-22 retest, the four DeepSeek models reported `reasoning_tokens` of 0 (or omitted the field), consistent with non-reasoning output for this minimal prompt.
   - **Scope Limit:** None of this proves tool-calling or autonomous coding; see gate G5.
   - **Key Finding:** `deepseek-v4-flash-vision-exp` succeeded even in the initial batch (before Global regions were enabled) because OpenCode routed the vision-experimental endpoint through non-restricted infrastructure, while its non-vision DeepSeek siblings were region-gated until the 2026-09-22 retest.

2. **Category 2: OpenCode Workspace Privacy Setting (Global Regions Required) — Resolved 2026-09-22**
   - **Affected Models (historical):** `deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-flash`, `deepseek-v4.1-flash`.
   - **Initial Evidence:** HTTP 500 / server_error with payload:
     `{"error":{"type":"server_error","message":"Upstream request failed: This Go model requires Global regions. Select Global in your workspace's Privacy settings to use it."}}`
   - **Cause:** OpenCode Go enforces geographic data routing boundaries; workspaces without Global regions enabled have these models rejected with the explicit error above.
   - **Retest Result (2026-09-22):** After the user manually enabled Global regions and authorized retesting, all four models were re-probed sequentially with the documented command shape and all four returned exit code 0 with exact `SANAD_MODEL_OK`. The region gate is confirmed resolved for the user's workspace; these models now count under Category 1.

3. **Category 3: OpenCode Workspace Privacy Setting (Training Data Required) (2 models) — High Confidence**
   - **Affected Models:** `muse-spark-1.2-contributor`, `muse-spark-1.3-contributor`.
   - **Evidence:** HTTP 500 / server_error with payload:
     `{"error":{"type":"server_error","message":"Upstream request failed: This Go model trains on request data. Allow paid endpoints that train on request data in your workspace's Privacy settings to use it."}}`
   - **Cause:** Contributor-tier models require an opt-in policy for model training in the OpenCode account workspace settings.

4. **Category 4: Upstream Endpoint Unavailable (4 models) — High Confidence**
   - **Affected Models:** `minimax-m2.7`, `grok-4.6`, `grok-4.7`, `gpt-5.6-luna`.
   - **Evidence:** HTTP 500 / server_error with payload:
     `{"error":{"type":"server_error","message":"Upstream request failed: Endpoint is unavailable."}}`
   - **Cause:** OpenCode Go still advertises these models in its discovery catalog, but its upstream reverse-proxy routes them to non-existent or decommissioned backends.
   - **Transient Retest Note:** In the batch execution, `grok-4.7` initially produced exit code 78 with the message `--standalone cannot use this Sanad Home while another runtime owns it` due to a momentary socket collision during gateway health probing; `--standalone` was never passed. A deterministic single rerun immediately produced exit code 1 with the identical `Endpoint is unavailable` provider fingerprint, proving the failure is upstream endpoint absence, not a permanent local socket defect. The same transient exit-78 pattern recurred once during the 2026-09-22 retest (`deepseek-v4.1-flash`) and resolved identically on immediate rerun.

---

## 6. Likely Owners & System Boundaries

| Subsystem / Layer | Owning Files | Responsibility |
|---|---|---|
| **OpenCode Workspace Settings** | External (OpenCode Dashboard) | User-controlled privacy settings: region constraints, training data permission. |
| **Sanad Provider Registry** | `agent/lib/engine/adapters/provider_registry.dart` | Curated fallback models, default base URL, headers, and protocol parameters. |
| **Sanad OpenAI Adapter** | `agent/lib/engine/adapters/base_openai_adapter.dart` | Translating HTTP errors, handling chat completion payloads, extracting reasoning tokens. |
| **Sanad Error Classification** | `agent/lib/engine/adapters/llm_http_exception.dart` | Mapping upstream provider error messages to typed actionable recovery hints. |
| **CLI Session Commands** | `agent/lib/cli/runner/commands/session_command.dart` | Daemon-backed list, show, stop, clarification response, and permission decisions. |
| **CLI One-Shot Runtime** | `agent/lib/cli/oneshot/oneshot_runner.dart` | Preserve clarification requests instead of auto-resolving them without an answer. |
| **Gateway Session State** | `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart` | Authoritative in-flight and pending-request projection. |
| **Delegation Skill** | `.agents/skills/sanad-delegate/SKILL.md` (new) | Instruction-only skill guiding orchestrators to drive native `sanad run` machine contract, brief ingestion, session identity, structured results, and timeout management. |
| **Delegate Supervisor** | `.agents/skills/delegate-task-supervisor/` | Multi-agent coordination, Sanad registration, intervention transitions, and event-first observation. |

---

## 7. Implementation Options & Candidate Solutions

### Option A: OpenCode Account-Side Configuration (User Action)
- ~~Enable **Global regions** in OpenCode workspace Privacy settings~~ — **Done (2026-09-22):** The user enabled Global regions manually; the retest confirmed `deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-flash`, and `deepseek-v4.1-flash` are now transport-successful (27 / 33 usable, or 81.8%).
- Enable **Paid endpoints that train on data** in OpenCode Privacy settings: Would unlock `muse-spark-1.2-contributor` and `muse-spark-1.3-contributor` (increasing usable models to 29 / 33, or 87.9%). **Out of scope:** training-data models/settings must not be tested or enabled by this task.
- *Trade-off:* Relies on external user configuration; does not resolve the 4 unavailable endpoints (`minimax-m2.7`, `grok-4.6`, `grok-4.7`, `gpt-5.6-luna`). This option is an external OpenCode privacy/settings action and is tracked separately from all Sanad-side gates; it must never block the `sanad-delegate` MVP.

### Option B: Adapter-Level Actionable Error Translation (Sanad Core)
- Extend `LlmHttpException` and `BaseOpenAIAdapter` to recognize OpenCode-specific error payloads.
- When an upstream response contains `"requires Global regions"` or `"trains on request data"`, normalize the error into a user-friendly actionable diagnostic:
  `OpenCode Privacy Constraint: Select Global regions in OpenCode workspace settings to use this model.`
- *Benefit:* Elevates cryptic server errors into clear, self-service operator guidance across CLI, Flutter UI, and delegated agents.

### Option C: Provider Catalog Pruning & Fallback Updating (Sanad Registry)
- In `provider_registry.dart`:
  - Prune `minimax-m2.7` from `fallbackModels` for `opencode-go`, ensuring `minimax-m3` and `minimax-m2.5` are prioritized.
  - Tag unavailable models as deprecated or filter them from the primary picker when live status checks fail.
- *Benefit:* Prevents users from selecting models that are known to have dead upstream backends.

---

## 8. Skill Topology & Delegation Contract

To enable automated delegation of coding tasks to Sanad Agent from external orchestrators (such as OpenCode, Antigravity, or multi-agent pipelines), the repository enforces a clear separation of concerns. `sanad-agentic-developer` is a **development SOP skill for human/agent-driven local runtime operations**, not a runtime component beneath the Sanad CLI; it sits outside the delegation call path:

```
┌─────────────────────────────────────────────────────────────┐
│                 delegate-task-supervisor                    │
│      (Orchestrator: Concurrency, Timelines, State)          │
└──────────────┬───────────────────────────────┬──────────────┘
               │                               │
               ▼                               ▼
┌──────────────────────────────┐ ┌───────────────────────────┐
│        sanad-delegate        │ │    opencode / agy-delegate │
│   (Instruction & Contract)   │ │    (Other Implementers)   │
└──────────────┬───────────────┘ └───────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────┐
│                       Sanad CLI                             │
│       `sanad run --brief-file <f> --out-dir <d> ...`        │
│        (attached to the active local daemon)                │
└─────────────────────────────────────────────────────────────┘

Separate development SOP (not part of the delegation call path):
┌─────────────────────────────────────────────────────────────┐
│                  sanad-agentic-developer                    │
│   (Development SOP: Worktrees, sanad-dev, Logs, Tests, PRs) │
└─────────────────────────────────────────────────────────────┘
```

### 8.1. `sanad-delegate` Skill (Global Instruction Skill)
- **Role:** Instruction skill teaching orchestrators to drive the native `sanad run` CLI machine contract.
- **Responsibilities:**
  1. Guides callers to invoke `sanad run` with `--brief-file` or stdin, model/provider overrides, a registered workspace (`--workspace`) or temporary unregistered filesystem context (`--execution-root`), and a timeout.
  2. Requires at least one targeting mode, keeps workspace identity/context/tools aligned, and makes workspace authoritative if both options are supplied; neither mode creates, selects, or switches workspaces.
  3. Pre-allocates and persists session ID prior to dispatch for concurrent observation and intervention.
  4. Uses file/stdin brief transfer rather than embedding large prompts in Windows argv.
  5. Enforces tool safety: gated tools are denied by default; explicit broad approval applies only to ordinary tool permissions and never answers `system_ask_user`.
  6. Captures terminal JSON and writes structured outputs (`result.json`, summary, exit code), while surfacing `needs_input` and `needs_permission` as non-terminal intervention states.
  7. Preserves session identity across iterative turns and manages cancellation with deterministic timeout and interrupt outcomes.

### 8.2. `delegate-task-supervisor` Skill (Orchestrator Extension)
- **Role:** The multi-agent supervisor.
- **Responsibilities:**
  1. Registers `sanad` as a supported implementer in `tasks.json` specifications. Workspace, brief, and output-directory arguments are semantic runtime values supplied by the supervisor (a target worktree path, a brief file, and a run-scoped result directory); the standard specification shape invokes the installed `sanad` binary:
     ```json
     {
       "id": "task-01",
       "implementer": "sanad",
       "workspace": "<target-worktree-path>",
       "command": "sanad",
       "args": ["run", "--brief-file", "<brief-file>", "--workspace", "<existing-logical-workspace-id>", "--provider", "OpenCode Go", "--model", "deepseek-v4-flash", "--out-dir", "<run-result-dir>", "--events"]
     }
     ```
     (Source development checkout fallback from the worktree root: `command: "fvm", args: ["dart", "run", "agent/bin/sanad_agent.dart", "run", ...]`).
     Placeholder tokens (e.g. `<target-worktree-path>`) are substituted at dispatch time; tracked documentation must not embed concrete machine paths or home-directory examples.
  2. Tracks progress by consuming the structured result and event timelines.
  3. Manages parallel worktree isolation and prevents cross-task lock contention.
  4. Honors the locked run topology: one supervisor run per reviewing orchestrator, known tasks in one shared spec, dynamic add/enqueue for later tasks, explicit close after reviews, and a single `watch-once` stream for all updates.

### 8.3. `sanad-agentic-developer` (Development SOP, Not a Runtime Component)
- **Boundary Contract:** `sanad-agentic-developer` is a development SOP skill, not a runtime component and not a layer beneath the Sanad CLI. It remains the developer's guide for local runtimes: controlling `sanad-dev`, hot-reloading the Flutter client, reviewing agent logs (`sanad-dev logs agent -n 100`), running analyzer checks, and preparing PRs. It must *not* duplicate delegation mechanics or task brief processing.

### 8.4. Core Sanad Requirement Assessment
- **Required Foundation:** Core CLI/gateway work is required before delegation: daemon-backed session inspection, stop, clarification response, permission decision, and safe one-shot handling of suspended questions.
- **Known Cause:** `OneshotRunner` currently sends every permission-stream event through the same auto allow/deny branch. With `--allow-all-tools`, a `system_ask_user` request is approved without an `answer`; suspended resume converts the missing answer to `''`, so the Client prompt disappears and the tool is recorded without a user response.
- **Required Correction:** `system_ask_user` must remain pending and produce `needs_input`; broad tool approval must not resolve it. Ordinary unresolved permissions produce `needs_permission`.
- **Terminal Result Contract:** The final JSON envelope (`session_id`, `text`, `tool_executions`, `exit_code`, `usage`, `model`, `provider`, `error`) remains authoritative only after terminal completion.
- **Live Structured Progress (Optional):** Full event streaming is deferred unless cheap. Queryable pending state and event-first intervention transitions are required; no terminal viewer is needed.
- **`opencode-delegate` Repair (Deferred):** Error-surfacing fixes remain low priority because `sanad-delegate` is intended to replace that path.

---

## 9. Security Constraints & Zero-Leakage Policy

1. **Credential Isolation:** OpenCode API keys and authorization tokens must remain in the `SecretStore` (`provider_secrets.json` inside the resolved Sanad Home). They must never be passed via CLI argv, logged to stdout/stderr, written into delegation briefs, or committed to git.
2. **Session Affinity:** OpenCode session affinity header (`x-opencode-session`) is generated dynamically from `sessionId` in `opencode_session_affinity.dart`. It must not be hardcoded or written into static configuration files.
3. **Workspace Boundary:** Logical conversation workspace and filesystem execution root are separate inputs. `sanad run` uses the existing `sanad-agent` workspace and executes tools only in the target isolated worktree; it never registers, creates, selects, or switches a workspace.
4. **Tool Approval Boundary:** Ordinary gated tools are denied by default. Broad approval requires explicit authorization and applies only to ordinary tool permissions; it never supplies or synthesizes a clarification answer.
5. **Intervention Identity:** Every answer or permission decision carries both `session_id` and `request_id`. The daemon rejects cross-session, stale, duplicate, resolved, or wrong-kind responses.
6. **Prompt Transport:** Delegation briefs use files or stdin rather than large Windows command-line arguments.

---

## 10. Execution Gates

### G0 — Evidence and Specification Alignment (Completed)
- [x] Verify and classify all 33 advertised OpenCode Go models.
- [x] Complete the user-authorized Global-regions retest.
- [x] Record the dated zero-tool compatibility matrix and delegation topology.

### External Track — OpenCode Privacy Settings (User-Owned)
- [x] Global regions enabled and retested.
- [ ] Training-data permission remains intentionally untested and out of scope.

### G1 — Daemon-Backed Session Observability and Intervention (Completed)
- [x] Implement real `session list`, `session show`, and `session stop` CLI commands against the daemon.
- [x] Include `in_flight` and the authoritative pending request in structured session output.
- [x] Add separate clarification-response and permission-decision commands bound to both session and request IDs.
- [x] Ensure `system_ask_user` is never auto-resolved by `--allow-all-tools` and remains pending until explicitly answered.
- [x] Reject stale, duplicate, mismatched-session, and wrong-kind responses.
- [x] Add focused unit and gateway/CLI integration coverage for suspension, inspection, response, resume, and stop.
- [x] Update the owning CLI/runtime technical and QA documentation.

### G2 — Native Delegation Machine Contract & Instruction Skill (Completed)
- [x] Create `.agents/skills/sanad-delegate/SKILL.md` instruction skill and integrate the delegation machine contract directly into `sanad run` CLI.
- [x] Accept briefs through a file (`--brief-file`) or stdin and record a known session ID before dispatch.
- [x] Add registered-workspace and execution-root targeting without mutating `Directory.current` or creating/selecting workspaces; the post-dogfood correction below separates logical conversation ownership from the filesystem execution boundary.
- [x] Implement timeout, interrupt, cancellation, and structured terminal `result.json` / `events.jsonl` behavior via serialized `RunArtifactCoordinator`.
- [x] Surface pending clarification and permission states without treating them as terminal completion.
- [x] Independent verification: analyzer clean; focused G2 suite 119/119; full CLI suite 260/260; relevant interface/runtime suite 115/115; full Agent fast suite 1883 passed and 26 skipped; `git diff --check` and secret/path scans clean. `graphify update .` rebuilt 7477 nodes, 9988 edges, and 679 communities; its untracked `.graphify/` cache was removed per repository policy.

### G3 — Supervisor Integration (`delegate-task-supervisor`) (Completed)
- [x] Register `sanad` as an implementer and document the native `sanad run` machine contract.
- [x] Implement one run per reviewing orchestrator with dynamic `add/enqueue`, explicit `close`, and event-first `watch-once`.
- [x] Emit `needs_input` and `needs_permission` transitions carrying session/request identity.
- [x] Verify scheduling across isolated worktrees without creating or switching Sanad workspaces.
- [x] Preserve the proven Windows detached-worker broker, add source-checkout FVM execution, fail-closed Sanad argument validation, snake_case identity handling, intervention-field whitelisting, and Windows-safe bootstrap probing.
- [x] Independent verification: all modified Node scripts pass `node --check`; supervisor suite passes 7/7 including dynamic lifecycle, intervention, restartable watching, FVM fallback, and isolated-worktree coverage; npm/npx bootstrap probes report real versions on Windows; `git diff --check` and secret/path/stale-contract scans pass. `graphify update .` rebuilt 7541 nodes, 9960 edges, and 665 communities; its untracked `.graphify/` cache was removed, with only the known unavailable PowerShell parser warning.

### G4 — agy-Driven Interactive Runtime Dogfooding
- [x] After the accepted G3 commit, fetch the latest `origin/main` and merge it into both the Task 98 and Task 78 worktree branches, preserving their existing work and resolving/verifying any conflicts before runtime testing. Both conflict-free merge commits were verified and pushed; Task 98 retained its 7/7 supervisor suite and Task 78 retained its original plan-only commit. The local Task 78 worktree was subsequently removed after the user corrected G5 to target Plan 97 instead.
- [x] Select the interactive SOP by tested surface: load and follow `Sanad Agentic Developer` for Agent/daemon/CLI-only interaction; if the scenario interacts with or validates Client UI behavior, also load and follow `Sanad Client Tester`. Merely launching a Client beside the Agent does not require Client UI automation.
- [x] Start exactly one managed Agent/Client pair on the dedicated test Home from the owning Task 98 worktree; verify ownership before mutation and stop it cleanly after testing. Never use runtime source handoff.
- [x] Have agy drive real Sanad CLI sessions through the daemon using provider `OpenCode Go` and model `deepseek-v4-flash`; the model selection applies to the Sanad sessions under test, while agy remains the external test driver.
- [x] Create a real session that produces a pending `system_ask_user`, then prove `session list/show`, identity-bound answer submission, continuation, and terminal completion.
- [x] Create a separate ordinary permission request, then prove pending inspection plus explicit allow and deny paths without broad approval answering a clarification.
- [x] Prove stale, duplicate, cross-session, and wrong-kind interventions fail without consuming the live request; prove `session stop` affects only the selected session.
- [x] Inspect bounded Agent and Client logs for clean lifecycle behavior and absence of credentials or sensitive payloads. Exercise managed restart recovery when needed to validate persisted pending decisions.
- [x] If any defect is found, fix it in the owning layer, add regression coverage and documentation, rerun the affected automated checks, and repeat the complete interactive scenario.
- [x] Record only redacted commands, identities, outcomes, and bounded evidence; never expose the user-configured API key or copy it outside the test Home.

G4 passed its original runtime matrix on 2026-09-22. The interactive run proved restart-safe clarification, explicit allow/deny, fail-closed intervention identity, scoped cancellation with exit 130, an unaffected independent session, structured artifacts, explicit supervisor close, one unchanged logical workspace, bounded clean final logs, and clean managed-runtime shutdown. Dogfooding found and fixed three owning-layer defects: the Local Gateway CLI previously disconnected before scoped stop delivery was transport-confirmed; OpenAI-compatible streaming preserved visible DeepSeek reasoning but not the raw `reasoning_content` required by OpenCode Go on later tool rounds; and the Local Gateway translator nested temporary session metadata instead of exposing `execution_root` to the runtime catalog. Focused regressions, the final 1,892-test Agent suite, and live tool-use reruns passed.

Post-dogfood contract correction:
- [x] Require at least one of `--workspace` and `--execution-root`; allow both when logical conversation ownership and filesystem execution must differ.
- [x] When both are supplied, retain `--workspace` as conversation identity while `--execution-root` independently owns tool/runtime context and artifact targeting.
- [x] Make `--execution-root` alone create only a temporary filesystem execution context, never a registered Sanad workspace.
- [x] Document the choice and precedence in owning docs plus `sanad-delegate` and `delegate-task-supervisor`, with regression and live-smoke coverage before G4 delivery.

### G5 — Delegation Tool-Use Proof and Acceptance
- [x] Use the existing Task 97 worktree as the real isolated implementation target, and have `sanad-delegate` with `deepseek-v4-flash` complete one genuine remaining Plan 97 task rather than a synthetic fixture. Session `0afa0c7c-70c7-445e-8990-17e28c8f66a1` completed 97b in its isolated worktree; Task 78 was not used.
- [x] Prove clarification persistence, explicit CLI answering, permission intervention, continuation, and stop through the completed native CLI machine contract and supervisor integration. Live medium runs covered clarification answer/resume, permission allow/deny, provider-timeout continuation, and scoped cancellation.
- [x] Prove default gated-tool containment and explicit broad-approval boundaries. Ordinary gated commands remained pending for identity-bound allow/deny; clarification was never auto-resolved, and no blanket broad approval was used during G5 acceptance.
- [x] Run owning analyzers, focused tests, relevant fast suites, and `graphify update .` after code changes. Agent analyzers were clean; focused suites passed for adapter replay and suspension, CLI/run/session behavior, gateway client and observability, execution-root propagation, delegation, and supervisor orchestration. The single final Agent full suite ran in the broader 97b engine/recovery worktree: 1811 passed, 26 skipped, 0 failed in 2m43s. Final Graphify updates rebuilt 7596 nodes / 10860 edges for Task98 and 7471 nodes / 10671 edges for 97b; the optional PowerShell parser was unavailable for 10 files and generated untracked caches were removed.
- [x] Review all diffs; do not commit, push, merge, or switch a runtime without fresh user authorization. Final `git diff --check`, generated-output status, secret/absolute-path scans, stale workspace-precedence scan, code/security review, and documentation review were clean. Commit and push were separately authorized for delivery after review; no merge, PR, or runtime switch was performed.

#### G5 dogfooding defects to repair before acceptance

- [x] Decouple the source checkout used to launch the source-development CLI from the delegated `--execution-root`. The supervisor now accepts a fail-closed `sourceRoot` only for validated FVM source-development tasks, resolves the requested entry point from that checkout, records the effective spawn root, and leaves the task `workspace` / CLI execution root unchanged. Focused supervisor coverage proves same-root compatibility, distinct source/execution roots, execution-root-only targeting, nested/private-consumer layouts, and invalid-root/invocation rejection on Windows.
- [x] Keep logical conversation workspace and filesystem execution root independent. `sanad run --workspace sanad-agent --execution-root <worktree>` now preserves both identities end to end: the registered workspace owns conversation continuity, while the explicit validated root owns tools/runtime context and artifacts. Supervisor validation checks every supplied execution root against the task workspace instead of ignoring it when a logical workspace is present.
- [x] Make `sanad session show --json` bounded and reviewer-focused by default. Return the execution/session owner identities, status, pending intervention, model, timestamps, and counts without embedding the complete conversation/history payload. Expose full messages/history only through an explicit opt-in (`--include-messages`). Inspect the existing compact CLI chat projection and adapt reusable ideas or primitives to this machine-review contract without copying its human presentation literally.
- [x] Preserve provider-owned `reasoning_content` across persisted clarification/permission suspension and CLI-driven continuation, not only across uninterrupted tool-loop rounds. A real `system_ask_user` answer had exposed `The reasoning_content in the thinking mode must be passed back to the API.` Root cause was empty streamed `reasoning_content` being collapsed to absent state on intermittent assistant tool-call messages. The adapter now preserves field presence independently from text length; focused adapter replay and suspended `system_ask_user` continuation regressions pass. A fresh OpenCode Go / `deepseek-v4-flash` run using explicit `medium` thinking then proved `needs_input → resumed → completed` with the exact expected answer and no provider continuity error.
- [x] Add explicit `sanad run --thinking-mode <effort>` support so delegated sessions can request `medium` without silently becoming `deep`; preserve `--thinking` as the backward-compatible deep shorthand and cover the daemon payload.
- [x] Make an explicit route/thinking-mode change on continuation complete its handoff and execute the requested turn. Root cause was the one-shot CLI treating the non-terminal `resuming` lifecycle notice (`Resuming…: Resuming last request with the new route.`) as a terminal error. Runtime notices now preserve status, and focused CLI coverage proves `resuming` remains attached through eventual turn completion while only `fatal` or unknown statuses terminate.
- [x] Keep `sanad run` attached while the daemon performs recoverable provider-timeout recovery. Root cause was the same unconditional runtime-notice failure path: a `waiting` notice ended the terminal artifact while daemon-owned auto-recovery continued. `waiting`, `blocked`, `resuming`, and `cleared` are now advisory/non-terminal; only `fatal` and unknown notices remain fail-closed. Focused coverage proves waiting-to-resuming-to-completed ownership without an early terminal result, and timeout/signal paths retain their existing scoped-stop contract.
- [x] Update CLI-only delegation startup guidance to launch the managed Agent without an unnecessary Flutter Client. Keep Client startup only for scenarios that actually exercise UI behavior, reducing resource use during delegated code work.
- [x] After the single-agent baseline succeeds, prove real multi-agent Sanad delegation with at least two concurrently active delegated sessions under one supervisor run, each targeting a distinct worktree and session. Two medium sessions ran concurrently with isolated artifacts and execution roots: session `8f530f2a-ea9d-4a37-b4a7-c1c0a77f1291` remained in `needs_input` and was later scoped-stopped (`cancelled`, exit 130), while session `27c1b81a-64fe-4a70-bd3c-95d5142f88f6` completed `MULTI_B:COMPLETED` without consuming or mutating the first intervention. The long-lived run used dynamic add/enqueue and was explicitly closed with completed status.
- [x] Collect any additional defects exposed by the complete 97b and multi-agent delegations before finalizing the repair scope; fix every accepted defect in its owning CLI/supervisor/skill layer with focused regression coverage and synchronized documentation. 97b exposed that a recoverable provider timeout first publishes `blocked` before daemon-owned `resuming`; the CLI now treats all non-fatal lifecycle states, including `blocked`, as non-terminal. It also proved the live source-root/logical-workspace/execution-root separation through a completed medium delegation.

### G6 — Provider Error Guidance (Optional; Never Blocks G1–G5)
- [ ] Optionally normalize OpenCode privacy errors.
- [ ] Optionally prune confirmed unavailable fallback endpoints.
- [ ] Add focused tests for any accepted optional change.

---

## 11. Acceptance Criteria

- [x] The dated G0 matrix accurately records all 33 advertised OpenCode Go models and its zero-tool proof boundary.
- [x] `session list/show` reports the daemon's actual session state, including `in_flight` and any pending clarification or permission request.
- [x] Given `system_ask_user` during non-interactive execution, the question remains pending with its options and is never resolved by `--allow-all-tools` or an empty answer.
- [x] A CLI clarification answer resumes only the matching session/request; stale, duplicate, cross-session, and permission-kind misuse fail without consuming the request.
- [x] A CLI permission decision follows the same identity guarantees through a separate command.
- [x] `session stop` stops the identified active session without affecting another session or runtime.
- [x] `sanad run` records its session ID before dispatch and targets a registered workspace, an unregistered temporary execution root, or both with independent logical-workspace and filesystem-execution semantics.
- [x] `watch-once` returns `needs_input` or `needs_permission` promptly instead of waiting for terminal completion.
- [x] In G4, agy drives the real daemon-backed CLI against OpenCode Go / `deepseek-v4-flash` and proves pending clarification, pending permission, list/show, answer/allow/deny, stop, bounded clean logs, and applicable restart recovery; any discovered defect is fixed and the complete scenario is rerun.
- [x] In G5, real `deepseek-v4-flash` delegations through the native `sanad run` / `sanad-delegate` contract proved tool use, user-question intervention, permission allow/deny, recoverable provider-timeout continuation, structured completion/cancellation artifacts, and isolated concurrent sessions.
- [x] No API keys, authorization tokens, absolute machine paths, workspace mutations, or unauthorized broad-tool approvals appear in tracked artifacts or runtime actions.

---

## 12. Definition of Done

- [x] G1 lands with owning contracts, technical/QA documentation, analyzer success, focused CLI/gateway/runtime tests, and the full Agent fast suite; `graphify update .` was attempted but unavailable because the Graphify CLI was not installed or discoverable on the review machine.
- [x] G2 lands as the native Agent-owned `sanad run` delegation machine contract and instruction-only skill with deterministic Windows-safe prompt transport, isolated execution roots, and serialized result artifacts.
- [x] G3 proves event-first intervention, dynamic enqueue, explicit close, and isolated-worktree scheduling.
- [x] G4 passes agy-driven interactive dogfooding and the post-dogfood targeting correction against one managed test runtime using OpenCode Go / `deepseek-v4-flash`, with real `shell_execute cd` evidence for both target modes and precedence, redacted artifacts, and clean shutdown.
- [x] G5 passes real medium `sanad-delegate` / `deepseek-v4-flash` delegations covering question, permission, continuation through provider recovery, stop, terminal output, multi-agent isolation, and explicit supervisor close.
- [x] Relevant fast suites pass with bounded output; G4 changed no port-binding integration/E2E boundary requiring an additional sequential suite.
- [x] `graphify update .` rebuilt the code graph after G4 and final G5 changes; the final G5 graph contained 7596 nodes, 10860 edges, and 625 communities. Its untracked local cache was removed. The final diff passed secret, absolute-path, stale-documentation, generated-output, security, and whitespace review.
- [x] Task98 G5 and Task97b commit/push delivery received fresh user authorization after final review. No merge, PR, runtime source handoff, or broad tool approval was requested or performed; each still requires separate fresh authorization.

---

## 13. Remaining Uncertainties & Decisions Needed

No blocking product or architecture decision remains before G1.

1. **Locked:** The delegation execution contract is native to `sanad run`. A run requires `--workspace`, `--execution-root`, or both. When both are supplied, the registered logical workspace owns conversation continuity and the execution root independently owns tool/runtime context in the isolated worktree; neither creates, selects, or switches another persistent workspace. An execution-root-only run remains temporary and unregistered. Documentation and delegation skills must explain when to use each mode. Clarifications and permissions retain distinct identity-bound commands, and `watch-once` exposes non-terminal intervention states.
2. **Optional Later Decision:** Whether to prune currently unavailable upstream models. This cannot block G1–G5.
3. **Snapshot Freshness:** Model availability remains dated evidence. Re-verify `deepseek-v4-flash` during G4 and again during G5 before relying on it for acceptance.
