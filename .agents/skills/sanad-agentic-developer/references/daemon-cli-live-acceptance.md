# Daemon CLI Live Acceptance Protocol

Use this reference when running live agent acceptance tests against a background Sanad daemon via the `sanad` CLI. It covers dynamic runtime discovery, Test-Home isolation, multi-phase session turns, direct session compaction, artifact verification, and anti-fiction constraints without UI conflation.

## 1. Operating Invariants

- **Dynamic Discovery (Never Hardcode Ports):** Dynamic ports (such as historical `58096`) are ephemeral to specific runtime instances. Never hardcode ports or loopback URLs in scripts. Discover the active daemon's gateway endpoint via `sanad-dev status` or allow the CLI to resolve it dynamically from `--home`.
- **Worker Home vs. Test Home Boundary:**
  - **Worker Home:** The normal environment (e.g., primary `~/.sanad` or developer worktree Home) where the orchestrating agent or developer operates.
  - **Test Home:** An isolated directory (e.g., `~/.sanad-test`) reserved exclusively for the daemon and session under test.
  - Never share credentials, authentication tokens, or live issuer state between the Worker Home and the Test Home.
  - **Authorized History Fixtures:** Synthetic histories or authorized, dependency-audited history fixtures (such as authorized unscoped subagent histories copied read-only with a manifest into disposable Test-Home instances) are permitted. Live credentials or auth tokens must never be copied.
- **Prohibition of Standalone Mode (`--standalone` Prohibited):** Daemon live acceptance verifies daemon-hosted execution (gateway WebSockets, session queue, background workers, compaction lifecycle). `--standalone` executes turns in-process, bypassing daemon infrastructure, and returns exit code `78` (ownership conflict) if a daemon is running on the target Home.
- **Same-Session Multi-Phase Sequences:** Multi-turn scenarios (seeding turn -> direct compaction admission -> continuation turn) must pass the exact same `--session <session_id>` to target the same canonical transcript on the daemon.
- **Timeout, Scoped Stop, and Ambiguous Request Invariants:** Native `sanad run` timeout actively attempts a scoped session stop over the gateway and persists `status: "timeout"` with exit code `124` to `result.json` and `events.jsonl`; it is not merely a client observation ceiling. However, a durable compaction operation running on the daemon may continue or settle independently—do not infer durable compaction cancellation from that stop. Retrying an ambiguous request automatically on timeout or error is strictly prohibited because it risks duplicate execution and session corruption. Inspect daemon logs and session state instead.
- **Admission != Completion:** CLI dispatch or admission (exit code `0`) indicates only that a turn finished or that a compaction request was accepted/dispatched. It is never proof of durable compaction completion or target criteria. Durable outcomes must be verified against persisted artifacts and database records.
- **CLI is Not UI Proof:** A matched Client should remain running and visible during live acceptance to verify peer visibility and event streaming. However, CLI success does not validate Client UI rendering, timeline updates, or toast behavior. UI assertions require separate UI driver or client test verification.
- **Privacy and Scalar Metrics:** Public task updates and reports must never include raw prompt bodies, model completions, thinking traces, or credentials. Report only scalar metrics: durations, token counts, cache ratios, exit codes, and status strings.

---

## 2. Command Reference

### A. One-Shot Turn Execution (`sanad run`)

```bash
fvm dart run agent/bin/sanad_agent.dart run \
  --brief-file <case-dir>/<phase>.txt \
  --execution-root "$PWD" \
  --session <session-id> \
  --provider "<provider>" --model <model> \
  --home <test-home> \
  --gateway-url <discovered-gateway-url> \
  --out-dir <case-dir>/<phase>-out \
  --quiet --timeout 240
```

Verified options (`agent/lib/cli/runner/commands/run_command.dart`):
- `--brief-file`, `-b`: Path to a non-empty file containing task prompt instructions. Mutually exclusive with inline prompt arguments; exits `2` if missing or empty.
- `--execution-root`: Working directory execution context for tool calls executed by the agent.
- `--session`, `-s`: Target session UUID to attach or resume.
- `--provider`: Provider override (e.g., `"OpenCode Go"`, `"openai"`), resolved by `ModelProviderResolver`.
- `--model`, `-m`: Model identifier override (e.g., `deepseek-v4.1-flash`).
- `--home`: Custom Sanad Home path targeting the isolated Test Home. Ensure shell tildes are expanded (e.g., `"$HOME/.sanad-test"`).
- `--gateway-url`: Discovered WebSocket gateway URL (e.g., `ws://127.0.0.1:<port>/ws`). When omitted, auto-discovered from `--home`.
- `--out-dir`, `-o`: Directory where `result.json` and `events.jsonl` are written by `RunArtifactStore`.
- `--quiet`, `-q`: Suppresses streaming tokens and progress banners, keeping stdout clean.
- `--timeout`: Maximum execution seconds (`1` to `86400`). On expiration, `sanad run` attempts a scoped session stop over the gateway and persists `timeout` (`124`) rather than acting as a passive observation ceiling. Do not infer durable compaction cancellation from that stop.
- `--thinking-mode`: Reasoning effort override (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `fast`, `balanced`, `normal`, `deep`).
- `--allow-all-tools`: Auto-approves gated tool permissions for automated execution.
- `--json`: Emits a single `OneshotResult` JSON object upon completion.

### B. Direct Compaction Admission (`sanad session compact`)

Compaction is **never** triggered by prompting the model. It is requested directly through the session compaction CLI:

```bash
fvm dart run agent/bin/sanad_agent.dart session compact <session-id> \
  --home <test-home> \
  --gateway-url <discovered-gateway-url> \
  --timeout 60
```

Verified options (`agent/lib/cli/runner/commands/session_command.dart`):
- `<session-id>`: Target session identifier (positional or via `-s, --session`).
- `--home`: Targets the Test Home daemon.
- `--gateway-url`: Discovered gateway WebSocket endpoint.
- `--timeout`: Maximum duration in seconds for the admission call.
- `--json`: Outputs machine-readable admission JSON payload.

Behavior and admission semantics:
- Invokes `compactSession(sessionId: id, resendOnTimeout: false)` over the gateway.
- Returns admission outcomes: `accepted`, `dispatched`, `no_op`, or failure (`failed`, `compaction_in_progress`, etc.).
- Exit code `0` confirms admission/dispatch, **not durable completion**. The daemon executes compaction asynchronously or within its coordinator lifecycle.
- Never resends on timeout; ambiguous timeouts must be investigated via daemon logs and state queries.

---

## 3. Discovery and Multi-Phase Workflow

### Step 1: Discover Active Runtime

From the workspace owning the target daemon:

```bash
fvm dart run scripts/sanad_dev.dart status
```

Confirm that the daemon is running, inspect the assigned Test Home path, and read the active gateway endpoint from the status output. Construct the gateway URL accordingly (e.g., `gateway_url="ws://127.0.0.1:<port>/ws"`).

Ensure a matched Client is running against the same Test Home and visible for peer observation.

### Step 2: Phase 1 — Baseline Context Seeding

Dispatch a normal agent turn using `sanad run` with `--brief-file` to establish conversational history:

```bash
fvm dart run agent/bin/sanad_agent.dart run \
  --brief-file "${case_dir}/phase1_seed.txt" \
  --execution-root "$PWD" \
  --session "${session_id}" \
  --provider "OpenCode Go" --model deepseek-v4.1-flash \
  --home "${test_home}" \
  --gateway-url "${gateway_url}" \
  --out-dir "${case_dir}/phase1-out" \
  --allow-all-tools \
  --quiet --timeout 240
```

Verify that the command exits `0` and inspect `<case-dir>/phase1-out/result.json`.

### Step 3: Phase 2 — Direct Session Compaction Admission

Request compaction directly for the active session:

```bash
fvm dart run agent/bin/sanad_agent.dart session compact "${session_id}" \
  --home "${test_home}" \
  --gateway-url "${gateway_url}" \
  --timeout 60
```

Confirm exit code `0` and that the CLI reports admission (e.g., `Compaction request accepted for session ...`).
Verify that the daemon registers the compaction operation in `CompactionBoundaryRepository` (`session_compaction_operations`) and reaches a terminal state (`completed`).

### Step 4: Phase 3 — Post-Compaction Continuation

Dispatch a subsequent turn on the **same session** to verify model continuation and fact retention across the compaction boundary:

```bash
fvm dart run agent/bin/sanad_agent.dart run \
  --brief-file "${case_dir}/phase3_continue.txt" \
  --execution-root "$PWD" \
  --session "${session_id}" \
  --provider "OpenCode Go" --model deepseek-v4.1-flash \
  --home "${test_home}" \
  --gateway-url "${gateway_url}" \
  --out-dir "${case_dir}/phase3-out" \
  --allow-all-tools \
  --quiet --timeout 240
```

---

## 4. Artifact Schema & Durable Verification

`RunArtifactStore` (`agent/lib/cli/artifacts/run_artifacts.dart`) produces two files in `--out-dir`:

### A. `result.json` (`RunResultArtifact`)

Top-level structure:
- `"$schema"`: `"https://sanad.dev/schemas/run-result-v1.json"`
- `"version"`: `"1.0.0"`
- `"session_id"`: String matching the targeted session UUID.
- `"status"`: Terminal state (`completed`, `failed`, `timeout`, `interrupted`, `cancelled`, `incomplete`, `needs_review`).
- `"exit_code"`: Integer exit code (`0` for success with semantic final summary, `1` for incomplete or failed, `124` for timeout).
- `"started_at"`, `"ended_at"`: ISO UTC timestamps with milliseconds.
- `"duration_ms"`: Total execution duration in milliseconds.
- `"text"`: Final assistant message text. Must satisfy `hasSemanticFinalSummary(text)`; missing or progress-only text triggers status `incomplete` and exit code `1`.
- `"terminal_output"`: Optional terminal envelope containing `session_id`, `status`, `exit_code`, and optional `"usage"`.
  - **Usage location and scope:** `terminal_output["usage"]` provides optional, aggregate turn-level usage (`prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_cache_hit_tokens`). Exact pre-call and first-post compaction occupancy cannot be established from aggregate turn usage alone; it requires request/step-bound receipts (such as paired request dumps) and durable operation records in `session_compaction_operations`.

### B. `events.jsonl` (`RunLifecycleEvent`)

NDJSON stream of lifecycle transitions where each line contains:
- `"timestamp"`: ISO UTC timestamp with milliseconds.
- `"type"`: Event name (e.g., `running`, `resumed`, `blocked`, `waiting`, `needs_permission`, `needs_input`, `completed`, `failed`, `timeout`).
- `"session_id"`: Session UUID.
- `"data"`: Context map containing event-specific fields (e.g., `exit_code`, `duration_ms`, `cause`, `error`).

### C. Anti-Fiction Checklist

To certify acceptance without fiction:
1. **Durable Compaction Record:** Confirm that `CompactionBoundaryRepository` persisted the compaction operation row in `session_compaction_operations` with status `completed` and matching message ranges.
2. **Usage & Occupancy Receipts:** `terminal_output["usage"]` in `result.json` may be aggregate or optional. Verifying exact pre-call occupancy and first post-compaction occupancy requires request/step-bound receipts (such as paired request dumps) and persisted `session_compaction_operations` operation records (`metrics` and `diagnosticsJson`), rather than relying on aggregate turn totals alone.
3. **No UI Conflation:** Do not treat CLI completion as proof of Client UI correctness. Verify Client UI independently if UI criteria are in scope.
