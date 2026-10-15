# Automated testing

Load this reference when selecting or running analyzer, unit, widget, integration, or E2E verification for Client changes.

## Selection order

1. Run `fvm flutter analyze` for Client code changes.
2. Run the focused unit or widget tests covering the changed behavior.
3. Run the full fast suite only for broad/shared changes.
4. Run E2E or integration tests only for real socket behavior, daemon/client contracts, persistent runtime state, app/bootstrap integration, worktree isolation, port ownership, or another boundary mocks cannot validate.
5. Use interactive UI verification only when deterministic tests cannot prove the behavior or visual/live evidence is required.

Unit and widget tests remain isolated: do not launch external servers or the daemon for them. Use `--concurrency=1` only when the selected E2E/integration tests bind shared ports or other exclusive resources.

## Bounded commands

Preserve command status and show only the final five lines by default:

```bash
set -o pipefail; fvm flutter analyze 2>&1 | tail -5
set -o pipefail; fvm flutter test <path> 2>&1 | tail -5
set -o pipefail; fvm flutter test 2>&1 | tail -5
```

For a port-binding test, append its supported sequential-execution option. If a command fails, rerun only that command without `tail` for diagnosis.

## Test correctness

- Do not use `Future.delayed` inside `testWidgets`; Flutter widget tests run in `FakeAsync`. Use `tester.pump`, `tester.pumpAndSettle`, or `tester.idle` according to the event being tested.
- Promote a successful reusable interactive scenario to the appropriate automated integration boundary instead of leaving it as an unexplained disposable script.
- Verify rendered state programmatically; logs alone are not acceptance evidence.
- Measure performance changes with comparable before/after evidence and regression coverage at the owning boundary.
