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
- **Tool Execution / Checkpoint Stale-Reuse Reproduction (97a) and Repair (97b):** In 97a a runnable, deterministic fixture in `agent/test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` proved that when `continuationMetadata` contains a completed result for a tool-call ID (for example `shell_execute_0`), a subsequent model step repeating that ID caused `ToolExecutionCoordinator.executeToolCalls` to reuse the prior result without executing the new call (stale-reuse mechanism observed repeatedly in the user logs). In 97b the same file became the regression suite asserting the repaired model-step-scoped reuse behavior and the required recovery scenarios (5 deterministic tests): reused provider IDs across model steps/turns with different arguments execute once; same-checkpoint replay, restart-after-durable-result and restart-during-side-effecting-tool preserve results without replaying side effects; no repeated-request loop. It does not claim exact parity with the complete ~15-iteration trace.
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
  - *Old-Suite Duration and Slowest Test Cases:* Run pre-existing test suites using `fvm dart test --reporter json` and calculate per-test durations (`testDone.time - testStart.time`) to record full suite duration and the ten slowest test cases on Windows.
- **Evidentiary Classification:**
  - *Measured Facts:* Host OS/hardware, FVM startup overhead (30 samples), Win32 FFI atomic write latency (30 samples), deterministic checkpoint reproduction test execution, static analyzer outcomes, and pre-existing test suite durations with ten slowest cases.
  - *Historical Baselines:* Pre-FFI PowerShell secure write taking >12,000 ms.
  - *User-Reported Baselines:* Continuous animated indicator CPU +15–30% and GPU 0→100% on Windows.
  - *Frozen Acceptance Invariant Budgets:* Static indicator zero GPU load (97j), 0 extra fetches on resize (97h), 100% deduplication of in-flight requests (97h), 0 duplicate session calls within 500ms debounce (97i), event-loop lag p50 < 50 ms / p95 < 200 ms (97f), and idle/tool-active history load p50 < 10ms/20ms (97f).
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

Central ledger and available measurements established in 97a on Windows host (Intel i9-9880H, Win 11 Build 26200, Flutter 3.47.0, Dart 3.13.0).
Numeric acceptance budgets are frozen. Rows marked pending or blocked are not measured baselines; each downstream owner must capture its pending baseline before changing that surface and then record matched after evidence.

| Metric / scenario | Baseline | Target / budget | After | Samples / mode | Result |
|---|---|---|---|---|---|
| Tool edit/read p50/p95 and event-loop lag P06 | Baseline: synchronous tool execution blocks microtask/event queue | Event loop unblocked; independent query completes before slow tool terminal result; lag budget p50 < 50 ms, p95 < 200 ms | pending | 30 samples planned (97f) | Budget frozen (97a) |
| History load p50/p95, idle vs tool-active | Baseline: atomic append + cached revision in c19bd57 | Zero history read lock contention during tool execution; idle load p50 < 10 ms, p95 < 25 ms; tool-active load p50 < 20 ms, p95 < 50 ms | pending | 30 samples planned (97f) | Budget frozen (97a) |
| Provider readiness p50/p95 P08 | Baseline: loading state previously conflated with absence | Distinct loading visible within 50 ms; 0 false absent flashes; startup resolution p50 < 500 ms, p95 < 1,500 ms | pending | unit/widget matrix (97g) | Budget frozen (97a) |
| CPU/GPU/frame timing P01 | User report: +15–30% CPU, 0→100% GPU with animated indicator; autonomous GPU counter sampling blocked | 0% continuous animation GPU load on Windows; static green dot and status chips (97j) | pending | Blocked autonomous GPU counter; static UI target frozen | blocked (profile/GPU counter); budget frozen (97j) |
| Resize/rebuild extra fetches P02 | User log: 2 duplicate pairs (`provider.usage.support`, `model.snapshot` in 162ms) | Exactly 0 extra Agent fetches for unchanged logical resources across 20 resize/rebuild cycles | pending | 20 resize cycles + rebuild/remount (97h) | Budget frozen (97a) |
| Equivalent simultaneous request P03 | Baseline: concurrent duplicate fetches observed on remount | Exactly 1 in-flight request per logical resource key (device/query scope); 100% request deduplication | pending | deterministic unit/widget test (97h) | Budget frozen (97a) |
| Request counts/bytes per action P04/P05 | User log: `get_sessions` repeated 9 times in 15ms | Exactly 1 fetch per workspace section/cursor; 0 redundant duplicate calls within 500ms debounce | pending | pagination test matrix (97i) | Budget frozen (97a) |
| Page sizes current 6/10 vs experiment 9/15 | Current default: initial 6, subsequent 10 | Adopt +50% page size (9/15) only upon payload overhead <15% and scroll request drop >=30% | pending | matched fixture experiment (97i) | Budget frozen (97a) |
| Secure write p50/p95 P10 | Historical (PowerShell): >12,000 ms. Win32 FFI a087238 baseline: cold 34.38 ms, warm p50 4.63 ms, p95 8.54 ms | <2,000 ms median or >=50% improvement | Independent 97c review, three matched current runs: p50 14.926–16.638 ms, p95 19.723–21.347 ms; direct-parent implementation on the same review host/load: p50 13.338–15.846 ms, p95 23.913–26.302 ms | 3 × 30 warm samples per implementation plus one cold sample per run; same host, fixture, SDK, and payload | Pass: current medians remain below 17 ms and the small parent/current variation is below the matched p95 noise; no regression is attributed to the immediate-delete repair |
| FVM startup overhead | Direct cached Dart: p50 1010 ms (min 1004ms, max 2079ms). FVM: p50 5051 ms (min 5023ms, max 6052ms). Delta p50: +4041 ms | Account for ~4.04s Windows FVM wrapper startup in test/command timeouts; direct cached Dart is diagnostic-only and does not replace FVM rule | Current: FVM overhead isolated | 30 samples direct Dart + 30 samples FVM | Measured & isolated |
| Test suite duration baseline | Suite durations: sanad_dev: 2.52s (156 tests); evolution: 58.7s (255 tests); engine: 12.54s; reproduction test: <1s. Top 10 slowest test cases recorded | Fast suites remain deterministic without unbounded sleeps; no unexplained regression | Current: baselines and 10 slowest cases recorded | FVM test --reporter json commands | Pass / Baseline established |
| Checkpoint tool-id reuse P07 | 97a: stale `completed_tool_results` keyed by provider id reused across model steps → non-progress loop | Every new causal invocation executes once; completed result reused only when model step, tool name, and structured arguments match; no repeated-request loop; no duplicate side effect | 97b: model-step-scoped reuse implemented; 5 regression tests pass; focused owning suites pass (89 + 93 tests, 0 failures) | `fvm dart test test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart` (6603 ms total incl. ~5.0s FVM bootstrap); `fvm dart test test/engine/agent_runner_test.dart` (9065 ms total incl. bootstrap) | Pass (97b fixes loop without replaying durable side effects) |

## Deterministic regression coverage

Rebuild/resize tests count commands, not elapsed sleeps. Event-loop responsiveness
uses a controlled slow handler and an independently completed query. Recovery
uses a fake provider with repeated IDs and explicit persisted checkpoints.
Widget tests advance their fake clock deliberately, not production timers or
unbounded settling while an animation repeats. Fast suites do not own live
ports; exclusive integration is isolated and sequential only where needed.

97b deterministic regression suite (implemented): `agent/test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart`, run with `fvm dart test test/engine/runtime/checkpoint_tool_identity_reproduction_test.dart`. It covers: reused tool IDs across model steps and turns with different arguments; same-checkpoint replay; restart after a durable result; restart during a non-idempotent side-effecting tool; and the no-repeated-request-loop/no-duplicate-side-effect invariants. Record the exact test file names and commands actually used once implemented.

97c Windows coverage is owned by
`scripts/sanad_dev/test/infrastructure/sanad_dev_secure_runtime_file_test.dart`.
It verifies exact protected owner-only ACL replacement, junction and root-escape
rejection, locked-destination typed failure and temporary cleanup, immediate
consumer deletion, concurrent atomic readers/writers, append/read containment,
and native backend failures. The final Windows ACL reassertion may be skipped
only when the published path is already absent; any failure while it still
exists remains fatal. The independent review run passed all 11 focused cases.

A separate 31-sample operation characterization on the same review host recorded
one cold sample followed by 30 warm samples: new directory 67.192 ms cold,
p50 8.417 ms, p95 10.946 ms; new atomic file 48.043/23.804/29.743 ms;
existing-file replacement 31.808/25.654/36.387 ms; new append file
10.418/18.731/29.303 ms; secure read 25.370/18.084/24.607 ms. These rows are
current-only diagnostics, not before/after improvement claims. All remain far
below the two-second acceptance budget and start no PowerShell subprocess from
the production Windows secure-file path.

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
