# Test Suite Performance and Ownership QA

## Purpose

This matrix prevents fast Agent and Client tests from silently accumulating
production timers, request timeouts, external resources, or tests owned by a
different package.

## Package ownership

| Surface | Owned coverage | Excluded coverage |
|---|---|---|
| Agent | daemon policy, persistence, capabilities, transports, and runtime behavior | Flutter widgets and developer-tool implementation |
| Client | Flutter state, widgets, repositories, and transport projections | Pure-Dart `sanad-dev` implementation |
| `sanad-dev` | CLI parsing, bootstrap, process discovery, ownership, journals, and runtime control | Client widget behavior |
| Shared endpoints | canonical non-secret environment-to-service mapping | Client or CLI orchestration |

The `sanad-dev` package must load, analyze, and run without Flutter dependencies.
Its platform wrappers and historical compatibility entry must both reach the
same package-owned CLI. A worktree smoke verifies help, stopped-runtime status,
and dry-run discovery without starting a runtime or changing source ownership.

## Deterministic timing matrix

- Request-failure tests explicitly fail or replace their fake transport; they do
  not wait for the production request timeout.
- Retry-policy tests bypass production backoff through a deterministic test
  service while dedicated recovery tests retain timer/cancellation coverage.
- Device-code tests inject the poll waiter; production keeps its minimum poll
  interval unchanged.
- Local reconnect tests inject only the delay policy and still observe the real
  `connecting` then `error` lifecycle transition.
- Scheduler tests separate registration from timer delivery. Registration is
  asserted from scheduled state; delivery awaits the exact event rather than a
  padded sleep.
- Asynchronous routing tests yield to the event queue only as required; fixed
  settling sleeps are prohibited.
- Wrapper, subprocess, filesystem-permission, and loopback-port tests remain
  narrow integration coverage. They are not converted into mocks when the OS
  boundary itself is the contract.

## Performance regression gates

For a changed hotspot, compare like-for-like warm runs. It passes when median
execution improves by at least 30 percent or falls below 250 milliseconds while
retaining its assertions. Full-suite comparisons distinguish package load and
compilation from case execution. E2E or tests sharing exclusive ports may run
sequentially; ordinary unit and widget suites retain default parallelism.

A regression fails this matrix when a fast test introduces a fixed wait of 100
milliseconds or more without a documented timing contract, relies on an
external network/provider, leaves a process or port active, or moves
package-owned coverage back under another product's test tree.
