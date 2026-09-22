# Windows-first Agent and Client Performance QA

## Scope and evidence status

Acceptance matrix for `docs/plans/97-windows-first-agent-client-performance.md`.
Measured Windows host environment established in 97a:
- **Host OS:** Microsoft Windows 11 Pro 64-bit (Version 10.0.26200, Build 26200)
- **CPU:** Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz (8 physical cores, 16 logical processors)
- **GPU 1 (Discrete):** NVIDIA Quadro T1000 (Driver: 32.0.15.9595, Status: OK)
- **GPU 2 (Integrated):** Intel(R) UHD Graphics 630 (Driver: 31.0.101.2140, Status: OK)
- **Flutter SDK:** Flutter 3.47.0 • channel stable • tools Dart 3.13.0
- **Dart SDK:** Dart SDK version: 3.13.0 (stable) on windows_x64
- **Runtime Test Isolation:** `%USERPROFILE%\.sanad-test` (isolated, verified stopped with 0 clients via single pre-run status probe before test execution)
- **Continuous Animation Baseline (User-Reported):** CPU +15–30% and GPU 0→100% with a single animated indicator; load drops to idle when indicator is removed. Hardware GPU counter sampling in autonomous CLI is marked blocked (requires interactive desktop release binary profiler); budget frozen for static indicator policy (97j).
- **Tool Execution / Checkpoint Loop Hypothesis (Owned by 97b):** Source inspection in `agent/lib/engine/runtime/tool_execution_coordinator.dart` (lines 77–130) shows that `completedResults` checks `containsKey(toolCall.id)` on shared continuation metadata without matching `model_step_id`, arguments, or assistant message. This provides a strong source-backed hypothesis for why repeated tool call IDs across model steps or turns might trigger successive "Resuming tool call ... from checkpoint" log events without executing. Task 97b must deterministically prove or disprove this hypothesis through a repeatable test fixture reproducing the exact resume loop before any implementation.
Windows acceptance is first; cross-platform verification follows Windows success.
Execution procedures live in the Sanad Agentic Developer and Sanad Client Tester
skills, not this QA record.

## Comparable measurement design

- Record source revision, OS, GPU/driver, power/display settings, SDK, renderer,
  build mode, transport, data-size distribution, and concurrent activity.
- Use an isolated, explicitly owned runtime with synthetic or safely prepared
  data. Never copy credentials, identity, live databases, or ACL-bound Home state.
- Keep baseline/current on the same host, fixture and mode. Capture at least 30
  samples per latency scenario and per cold/warm class, separately.
- **Reproducible 30-Sample Measurement Procedures (established in 97a):**
  - *FVM Startup Overhead:* Execute 30 iterations of `fvm dart --version` and 30 iterations of direct `dart --version` (invoking the Dart SDK binary cached under `%USERPROFILE%\fvm\versions\3.47.0\bin\dart.bat` solely as an isolated diagnostic comparison to measure Windows batch-wrapper overhead; does not replace the global repository FVM law), recording per-invocation wall-clock time with `System.Diagnostics.Stopwatch` to separate Windows batch-wrapper JIT overhead from Dart SDK execution.
  - *Secure Runtime File Atomic Write (Win32 FFI):* In a clean temporary directory under `%USERPROFILE%\.sanad-test` or system temp, execute 1 cold write followed by 30 warm sequential atomic writes of a sample JSON payload using `secureRuntimeAtomicWrite` from `package:sanad_dev/src/infrastructure/secure_runtime_file.dart`, recording per-write elapsed microseconds with `Stopwatch`.
- **Evidentiary Classification:**
  - *Measured Facts:* Host OS/hardware, FVM startup overhead (30 samples), Win32 FFI atomic write latency (30 samples), static analyzer outcomes, and existing focused test durations.
  - *Historical Baselines:* Pre-FFI PowerShell secure write taking >12,000 ms.
  - *User-Reported Baselines:* Continuous animated indicator CPU +15–30% and GPU 0→100% on Windows.
  - *Source-Backed Inferences:* `ToolExecutionCoordinator` continuation dictionary keying forming the strong hypothesis for 97b.
  - *Pending / Blocked Measurements:* Tool event-loop lag (pending 97f), history load under active tool IO (pending 97f), provider readiness (pending 97g), request counts/bytes pagination (pending 97i), and GPU hardware counters (blocked in CLI).
- For CPU/GPU/frame evidence use matched idle / one indicator / many indicators
  observation windows, at least three repeats, and record their duration. Use
  the same GPU engine/counter and sampling tool. Distinguish percentage points
  from relative percentages and report noise, not just a maximum screenshot.
- Driver/debug evidence proves interaction and correctness, not release rendering
  performance. Profile/release measurements accompany driver evidence, without
  inventing driver support for a build that lacks the required extensions.
- Monotonic timings are process-local: correlate request IDs across components,
  but do not subtract unrelated monotonic clocks. Measure end-to-end at one
  observer and durations inside each process separately.
- Baseline records request type, opaque scope/query/cursor identity, count and
  bytes; diagnostic instrumentation is opt-in, bounded and redacted. No raw
  user content, tokens, paths or account/device identifiers in published evidence.

## Scenario matrix

| ID | Scenario | Observable acceptance | First / final coverage |
|---|---|---|---|
| P01 | Idle, one spinner, multiple active tools and session dots | No continuous activity ticker on targeted Windows surfaces; CPU/GPU within agreed static budget | Windows profile/release; other desktop regression last |
| P02 | 20 compact/wide resize cycles, theme rebuild, responsive remount | Zero additional Agent fetches for unchanged logical resources | Windows fake transport + driver; macOS regression last |
| P03 | Two consumers of same provider snapshot/support | One in-flight request per equivalent device/query; no wrong-device cache reuse | Windows unit/widget/integration |
| P04 | Open app, switch device/session, send/edit message, provider page | Measured per-action budget; required authoritative updates preserved | Windows, mobile final |
| P05 | Many workspaces and sessions; page and history scrolling | No duplicate cursor requests or missing rows; distinguish section fan-out from pagination | Windows; final desktop/mobile |
| P06 | Slow edit/read while independent local/cloud query arrives | Query received and completed before deliberately slow tool terminal result; measured p95 budget | Windows integration + final driver |
| P07 | Restart rate-limit wait; repeated tool IDs across model steps | Forward progress, correct result ownership, no repeated side effects or retry storm | Windows deterministic provider + lifecycle |
| P08 | Known configured provider startup, delayed credentials/catalog | Loading distinct from absence; configured usable provider never falsely absent | Windows; final other platforms |
| P09 | Delayed device inventory, empty success, error, reconnect | Loading/stale/error/authoritative empty distinct; no no-devices flash | Windows widget/mobile layout; real mobile last |
| P10 | Secure write/race/locked file/interruption/consumer delete | Exact ACL and atomicity; no unsafe or temporary residue | Windows; POSIX mandatory final |
| P11 | Stale launcher and exact/foreign/ambiguous components | Fail-closed admission and cleanup; no primary runtime mutation | Windows; hosted other platforms final |
| P12 | Full managed run/restart/reload/stop | Correct ownership, UI state, endpoint cleanup | Last interactive gate, Windows first |

## Baseline and result ledger

Partially established in 97a on Windows host (Intel i9-9880H, Win 11 Build 26200, Flutter 3.47.0, Dart 3.13.0).
Available baselines and static indicator policies recorded; missing numeric p50/p95 budgets remain pending at their respective owning tasks (97f, 97g, 97h, 97i) before implementation.

| Metric / scenario | Baseline | Target / budget | After | Samples / mode | Result |
|---|---|---|---|---|---|
| Tool edit/read p50/p95 and event-loop lag P06 | Pending 97f | Event loop unblocked; independent query completes before slow tool terminal result; numeric p50/p95 lag budget pending 97f | pending | 30 samples planned (97f) | planned (97f) |
| History load p50/p95, idle vs tool-active | Not measured (historical optimization in c19bd57 used atomic append + cached revision; active/idle latency baseline pending 97f) | No history read lock contention during tool execution; numeric latency budget pending 97f | pending | 30 samples planned (97f) | planned (97f) |
| Provider readiness p50/p95 P08 | Pending 97g | Distinct loading vs absent/error states; usable provider never falsely absent | pending | unit/widget matrix (97g) | planned (97g) |
| CPU/GPU/frame timing P01 | User report: +15–30% CPU, 0→100% GPU with animated indicator; autonomous GPU counter sampling blocked | 0% continuous animation GPU load on Windows; static green dot and status chips (97j) | pending | Blocked autonomous GPU counter; static UI target frozen | blocked (profile/GPU counter); budget frozen (97j) |
| Resize/rebuild extra fetches P02 | User log: 2 duplicate pairs (`provider.usage.support`, `model.snapshot` in 162ms) | 0 extra Agent fetches for unchanged logical resources across 20 resize/rebuild cycles | pending | 20 resize cycles + rebuild/remount (97h) | planned (97h) |
| Equivalent simultaneous request P03 | Not measured; user observed duplicate pairs on remount (deterministic request budget owned by 97h) | Exactly 1 in-flight request per logical resource key (device/query scope); budget owned by 97h | pending | deterministic unit/widget test (97h) | planned (97h) |
| Request counts/bytes per action P04/P05 | User log: `get_sessions` repeated 9 times in 15ms | 1 fetch per workspace section/cursor; duplicate requests coalesced | pending | pagination test matrix (97i) | planned (97i) |
| Page sizes current 6/10 vs experiment 9/15 | Current default: initial 6, subsequent 10 | Adopt +50% page size (9/15) only upon measured net latency/bandwidth benefit | pending | matched fixture experiment (97i) | planned (97i) |
| Secure write p50/p95 P10 | Historical (PowerShell): >12,000 ms. Current (Win32 FFI a087238): Cold 34.38 ms, Warm p50: 4.63 ms, p95: 8.54 ms | <2,000 ms median or >=50% improvement | Current: p50 4.63 ms, p95 8.54 ms | 30 warm samples (min 3.82ms, max 9.55ms) + 1 cold | Pass (99.9% reduction from historical PowerShell baseline; meets <2,000 ms budget with >1,990 ms headroom) |
| FVM startup overhead | Direct cached Dart: p50 1010 ms (min 1004ms, max 2079ms). FVM: p50 5051 ms (min 5023ms, max 6052ms). Delta p50: +4041 ms | Account for ~4.04s Windows FVM wrapper startup in test/command timeouts; direct cached Dart is diagnostic-only and does not replace FVM rule | Current: FVM overhead isolated | 30 samples direct Dart + 30 samples FVM | Measured & isolated |
| Test suite duration baseline | Agent message history: 3s (10 tests). Sanad-dev secure runtime: <1s (6 tests). Agent analyze: clean (<15s). Client analyze: clean (46.9s) | Fast suites remain deterministic without unbounded sleeps; no regression | Current: baselines recorded | FVM test/analyze commands | Pass / Baseline recorded |

## Deterministic regression coverage

Rebuild/resize tests count commands, not elapsed sleeps. Event-loop responsiveness
uses a controlled slow handler and an independently completed query. Recovery
uses a fake provider with repeated IDs and explicit persisted checkpoints.
Widget tests advance their fake clock deliberately, not production timers or
unbounded settling while an animation repeats. Fast suites do not own live
ports; exclusive integration is isolated and sequential only where needed.
Record the exact test file names and commands actually used once implemented.

## Final interactive evidence

97l follows successful static, unit/widget and relevant integration results.
The selected Client exposes the driver entry point and stable keys; discovery
uses the current worktree's validated ownership and badge. Snapshot/find precede
actions. Evidence includes UI results as well as bounded Agent/Client logs.
Missing keys are inspected in source rather than bypassed by guessed clicks.
A mobile/web driver requires a reachable explicit VM endpoint and driver entry
point; desktop discovery is not evidence of mobile connectivity. Windows Job
containment failures remain failures: a human-owned terminal can provide the
supported launch path without enabling generic breakaway. Only disposable
runtimes created for the test are cleaned up.

## Report and regression decisions

For duration/count/bytes with positive baseline, improvement is
`(before - after) / before * 100`. Report absolute values and distributions too.
CPU/GPU report percentage-point differences as well as any valid relative change.
Zero baseline is N/A for relative improvement. No aggregate percentage combines
unrelated metrics. Old-suite slowdown is separated from added-test time and
startup overhead; any unexplained increase blocks the affected acceptance.

High-complexity low-benefit optimization records a defer decision, measured
benefit, complexity, owner and revisit trigger. Security, lost events and
incorrect execution are not waived. Missing host/CI evidence is blocked, never
passed. Final cross-platform coverage includes two hosted complete sanad-dev
runs per supported OS where required by the owning historical baseline task.
