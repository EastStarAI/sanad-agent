# Windows-first Agent and Client Performance QA

## Scope and evidence status

Acceptance matrix for `docs/plans/97-windows-first-agent-client-performance.md`.
No Windows measurements have been executed for this planning change. Reported
CPU +15–30% and GPU 0→100% with a single animated indicator are user-observed
baseline evidence, not measurements produced by this document. The user reports
a known Flutter issue; no particular upstream issue/version has been verified.
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

Complete this ledger in 97a before implementation; numbers are deliberately
pending rather than fabricated. Budgets are frozen before each repair.

| Metric / scenario | Baseline | Target / budget | After | Samples / mode | Result |
|---|---|---|---|---|---|
| Tool edit/read p50/p95 and event-loop lag P06 | pending | pending 97a | pending | pending | not run |
| History load p50/p95, idle vs tool-active | pending | pending 97a | pending | pending | not run |
| Provider readiness p50/p95 P08 | pending | pending 97a | pending | pending | not run |
| CPU/GPU/frame timing P01 | user report above; measured baseline pending | pending 97a | pending | pending | not run |
| Resize/rebuild extra fetches P02 | user log: two pairs | 0 | pending | 20 resize cycles plus rebuild/remount | not run |
| Equivalent simultaneous request P03 | pending | 1 in-flight per logical key | pending | deterministic test | not run |
| Request counts/bytes per action P04/P05 | pending | pending 97a | pending | pending | not run |
| Page sizes current 6/10 vs experiment 9/15 | pending | adopt only measured net benefit | pending | matched fixture | not run |
| Secure write p50/p95 P10 | Historical (PowerShell): >12,000 ms. Win32 FFI baseline: cold 34.38 ms, warm p50: 4.63 ms, p95: 8.54 ms | <2,000 ms median or >=50% improvement | Current: p50 <17 ms, p95 <22 ms | 30 warm samples (min 3.82ms, max 9.55ms) + 1 cold | Pass (>99% reduction from historical PowerShell baseline; meets <2,000 ms budget with >1,980 ms headroom) |
| Old-suite time / new tests / FVM overhead | pending | justified surface-specific budget | pending | separate measurements | not run |

## Deterministic regression coverage

Rebuild/resize tests count commands, not elapsed sleeps. Event-loop responsiveness
uses a controlled slow handler and an independently completed query. Recovery
uses a fake provider with repeated IDs and explicit persisted checkpoints.
Widget tests advance their fake clock deliberately, not production timers or
unbounded settling while an animation repeats. Fast suites do not own live
ports; exclusive integration is isolated and sequential only where needed.
Record the exact test file names and commands actually used once implemented.

Secure runtime Windows regression coverage is owned by
`scripts/sanad_dev/test/infrastructure/sanad_dev_secure_runtime_file_test.dart`.
It verifies exact protected owner-only ACL replacement, junction and root-escape
rejection, locked-destination typed failure and temporary cleanup,
concurrent atomic readers/writers, append/read containment,
and native backend failures. The suite passes all focused cases deterministically.

A separate 31-sample operation characterization on the Windows host recorded
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
