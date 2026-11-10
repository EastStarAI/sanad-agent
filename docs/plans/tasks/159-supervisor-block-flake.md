# Task 159 — Supervisor block-flake: one parked turn, one cause

- Status: delivered (PR: `fix/supervisor-block-flake`)
- Owning area: `.agents/skills/delegate-task-supervisor`
- Related: task 157 (incident regression suite), PR390 (the scenario that flaked)

## Goal

Make `2026-11-09/block-reaches-the-journal-early` deterministic and remove the two
supervisor leaks and the cross-file sweep hazard that turned one merge-queue run
into a release-blocking flake — including the second, same-shape failure that
followed it an hour later (`one open run stays alive after initial tasks settle…`).

## Locked decisions and scope

- The flake is a **test** defect: the scenario awaited the follow's entry record
  and then asserted a state the *next* record produces. It is not a user-visible
  product race — `following` is neither actionable nor watchable.
- Two writes cannot be assumed adjacent across processes. The scenario awaits the
  exact record it asserts; no sleep, no retry, no weakened assertion.
- The second merge-queue failure (`one open run…`, `supervisor_test.mjs:315` at the
  queue base) is the **same** composition, not the sweep: no test file performs a
  non-dry-run sweep except its own, `watch` reads the journal, `status` reads the
  manifest, and the manifest settles one write later. It is fixed the same way.
- The product change is one line: the follow's entry record carries the durable
  cause it just read (`snapshot.cause`), falling back to the transport's terminal
  cause. One parked turn therefore has one cause in the journal and in the
  manifest, at every observation point.
- Teardown sweeps are file-scoped: a sweep names only the fixture families its own
  test file creates, because `node --test test/*_test.mjs` runs files
  concurrently.
- The two leaking tests (`delegate-watch-cursor-test-`, `delegate-progress-stall-test-`)
  get a one-line `close --wait`, because a run's supervisor is not the task and
  outlives the last settled task.
- Out of scope: production delay hooks, CI retries, any change to the watched
  status sets, and the two arm64 CI lanes.

## Gates

### G0 — Discovery (done)

- [x] Reproduce the mechanism from the merge-queue log and the fixture source.
- [x] Prove the writer chain: artifact cause `blocked` → `workerCause` → entry
      record cause → mirror cause.
- [x] Rule out shared temp dirs, ports, and leftover processes as the cause.
- [x] Prove causality with a copy of the skill that widens the two-write gap.

### G1 — Implementation (done)

- [x] `scripts/supervisor-worker/follower.mjs`: the entry record prefers
      `snapshot.cause`.
- [x] `test/incident_regression_test.mjs`: assert the entry record's cause, then
      await the mirrored `blocked` record and the manifest it persists.
- [x] `test/supervisor_test.mjs`: await the manifest projection before the
      `status` assertions of the long-lived-run scenario.
- [x] `test/process_guard.mjs`: `sweepOrphanedFixtures({ prefixes })`.
- [x] `test/supervisor_test.mjs`: register its own fixture families, guard the
      list, and close the two leaked runs.
- [x] `test/incident_regression_test.mjs`: sweep only `delegate-incident-`.
- [x] `test/process_guard_test.mjs`: cover the declared-scope behaviour.

### G2 — Documentation (done)

- [x] `SKILL.md`: the entry `following` record carries the durable cause.
- [x] `docs/operations/continuous_integration.md`: concurrent files, file-scoped
      sweeps, exact-record awaits.
- [x] `docs/llms.txt`: index this task.

### G3 — Delivery (open)

- [ ] PR opened with the labels the changed paths require.
- [ ] Exact-head CI green.

## Acceptance Criteria

- [x] The scenario fails on a pre-fix skill whose entry record carries the
      transport's `blocked` cause with a widened gap between the two writes
      (`actual: 'blocked'`), and passes on the fixed skill.
- [x] The scenario passes when the *product* cause is fixed but the gap is still
      40 ms, proving the await does not depend on the writes being adjacent.
- [x] The new entry-cause assertion fails on the pre-fix product with the message
      `the entry record names the durable cause`.
- [x] A full suite run reaps **zero** leftover supervisors (previously two, in
      every run), in five consecutive runs.
- [x] The long-lived-run scenario asserts the manifest projection it reads, not the
      journal record that precedes it.
- [x] `sweepOrphanedFixtures` scans only the families its caller declares, and a
      new fixture family that is not registered fails the guard test.

## Definition of Done

- [x] `node --test test/process_guard_test.mjs`, `test/incident_regression_test.mjs`,
      `test/supervisor_test.mjs`.
- [x] `node --test test/*_test.mjs` (the CI shape), five consecutive runs,
      136/136 each and zero reaped leftovers.
- [x] Owning docs updated in the same change.
- [x] No secrets, personal paths, generated output, or dependency changes.
- [ ] Exact-head CI green on the pull request.
- [ ] Graph refreshed (`graphify update .`) when the branch is final.

## Manual regression check (the mutant recipe)

The composition is only observable when the worker is preempted between its two
writes, so the check is deterministic instead of load-dependent. Run it in a copy
outside the repository — it must never touch the tracked tree:

```bash
rm -rf /tmp/mutant-159 && cp -R .agents/skills/delegate-task-supervisor /tmp/mutant-159
# scripts/supervisor-worker/follower.mjs:
#   confirmFollow(task, snapshot);                      -> await confirmFollow(task, snapshot);
#   const confirmFollow = (task, snapshot) => {          -> async (task, snapshot) => {
#   applyFollowSnapshot(task, snapshot);                -> await new Promise((r) => setTimeout(r, 40));
#                                                          applyFollowSnapshot(task, snapshot);
TMPDIR=$(mktemp -d) node --test \
  --test-name-pattern="block-reaches-the-journal-early" \
  /tmp/mutant-159/test/incident_regression_test.mjs
```

- Against a **pre-fix** `follower.mjs` (entry cause = transport cause): fails in
  ~1.9 s with `actual: 'blocked'`, `expected: 'network_error'` — the merge-queue
  failure.
- Against the **fixed** `follower.mjs`: passes even with the 40 ms gap.

A green run of the scenario on an unmodified skill proves nothing about this
composition; the gap is what makes it observable.

## Current status

G0–G2 closed with the evidence above. G3 is open pending review and exact-head
CI. Follow-ups recorded here rather than implemented: none outstanding — the two
leaks and the sweep scope landed in this change.
