# Task 157 — Supervisor Incident Regression Suite and Restart-Tolerant Following

Status: implemented (public `EastStarAI/sanad-agent`), one pull request, Agent and Client untouched.

Study: `~/.sanad-delegate/runs/supervisor-stall-regression-20261109/STUDY.md` (local evidence, not tracked).

## 1. Owner report

Between `05:25Z` and `05:28Z` on 2026-11-09 a provider outage stopped four tasks in
`live-tooling/run13`. The owner saw them stopped in the Client, restarted the primary daemon, and
pressed Retry in each conversation. The coordinator's watcher printed exactly one line
(`05:26:31Z merge-366 following -> blocked`), and the supervisor itself reported all four tasks as
`follow_lost` (`3 consecutive session reads failed`) at `05:35Z` — while the daemon sessions were
alive and `resuming` minutes later. The question was why a previously fixed alerting path had
regressed again.

## 2. What the evidence showed

| # | Owner | Defect |
|---|---|---|
| A | coordinator watcher (`watch --once` + manual re-run) | The journal was complete and lossless; delivery was not. The watcher exited on the first batch, so three `blocked` transitions and four `follow_lost` records stayed unread until `05:43Z`. |
| B | `supervisor-worker/follower.mjs` | Every unreadable probe was the same failure. Three of them (90 s) ended a confirmed follow permanently, so a daemon restart outlived the tolerance and produced a fabricated terminal verdict. |
| C | `supervisor-worker/follower.mjs` | The CLI's own `error_code: session_not_found` was discarded, because `probe.ok` is `exit code === 0` and the payload was never parsed on failure. "Gone" and "not answering" were indistinguishable by construction. |
| D | `supervisor-worker/follower.mjs` | `follow.lastError` recorded `session show exited 1`: the stderr the CLI wrote was thrown away, so the report could not be diagnosed. |
| E | `supervisor.mjs` / `supervisor-views.mjs` / `context.mjs` | A run never recorded which code it executes and `status` never compared it with `origin/main`. `run13` ran `e7d9a155` for five hours across three merged fixes, and nothing said so. |
| F | `supervisor-watch.mjs` | `enrichWatchEvent` printed `result-file undefined` for a followed verdict, which has no artifact path. |
| G | `.github/workflows/ci.yml` | No lane executed the supervisor's Node suite at all, so no regression in it could fail a pull request. |
| H | `test/supervisor_test.mjs` | The only unreadable-read test asserted the harmful behaviour (a permanently missing session → `follow_lost` after two polls) and the mock could not express "down, then back". |

## 3. Decisions and what was implemented

1. **Classify before ending a follow.** `followReadFailure` (`scripts/supervisor-follow.mjs`) is the
   one pure rule: `session_not_found` is definitive (poll floor only), every other failure is
   transient and is tolerated until `--follow-unreadable-grace-ms` (default `300000`, named
   `DEFAULT_FOLLOW_UNREADABLE_GRACE_MS`) has also elapsed. The window is measured from the first
   failure of an outage, so a flapping daemon earns one window per outage.
2. **Resume the same session.** A recovered read clears `firstFailureAt`, `degradedAt`,
   `unreadableForMs`, and the poll budget; the follow continues with no re-follow command, no new
   attempt, and no lost conversation. One non-actionable `follow_unreadable` record per outage names
   the failure count, the window, and the tolerated-until instant.
3. **Still terminal, still actionable.** An expired window ends `follow_lost` with cause
   `session_unreadable` and an `error` carrying the failure count, the elapsed wait, the window, and
   the CLI's stderr. A definitive answer ends it with cause `session_not_found`. `follow_lost`
   remains in `TERMINAL_STATUSES`, which makes it actionable through the shared vocabulary.
4. **A watcher that cannot silently stop consuming.** Additive `watch --linger-sec <n>`: after the
   first batch a `--once` watcher keeps streaming for `n` seconds, and `--timeout-sec` re-arms per
   printed batch. Default `0` keeps the documented one-shot contract byte-for-byte.
5. **A stale-code guard.** `start` records `code` (`root`, `commit`, `shortCommit`, `branch`,
   `dirty`) in the manifest and the handshake; the worker carries it forward on every rewrite;
   `status` prints a `CODE` line, `status --brief` adds `code=<short>` and
   `CODE_BEHIND_ORIGIN_MAIN=<n>`, and `--json` carries `code`/`codeStaleness`. The comparison is
   offline against the locally known `origin/main` and never fails the read.
6. **One named scenario per incident, gated by CI.** `test/incident_regression_test.mjs` holds nine
   scenarios (§4). A new `Supervisor skill tests` job runs the whole Node suite on the `agent`
   classification and is part of `All required checks pass`.
7. **Scope.** Supervisor skill, CI lane, and docs. No Agent, Client, or daemon change.

## 4. Definition of Done

| Item | Evidence |
|---|---|
| Restart survives a follow | `test/incident_regression_test.mjs` → `2026-11-09/daemon-restart-survives-follow` (fails on `origin/main`: settles `follow_lost`) |
| Expired window alerts with a real cause | → `2026-11-09/restart-window-expires` (fails on `origin/main`: no grace, `exited 1` only) |
| Gone vs unreachable | → `2026-10-23/gone-vs-unreachable` (fails on `origin/main`: `followReadFailure` absent) |
| Outage stop wakes the watcher | → `2026-11-09/outage-block-alerts` |
| `follow_lost` is a wake-up and names no file | → `2026-11-09/follow-lost-wakes-a-watcher` (the `undefined` assertion fails on `origin/main`) |
| Scheduled retry is not a stall | → `2026-11-08/scheduled-retry-not-a-stall` |
| `--new-session` keeps the pin | → `2026-11-09/continue-session-pin` |
| Stale code is visible | → `2026-11-09/stale-supervisor-code` (fails on `origin/main`: no module) |
| Watcher keeps consuming | → `2026-11-09/watcher-keeps-consuming` (fails on `origin/main`: `--linger-sec` ignored, second alert never printed) |
| Existing behaviour preserved | `node --test test/*_test.mjs` from `.agents/skills/delegate-task-supervisor` — mechanism suite plus the incident suite, all passing |
| Follow semantics documented | `.agents/skills/delegate-task-supervisor/SKILL.md` (§5 watch, §5.1 follow, included scripts), `docs/agent_engine/sanad_delegate_relay.md` §5.5/§5.12/§5.14 |
| The lane exists and gates | `.github/workflows/ci.yml` `supervisor-skill`, `all-required` needs + result check; `docs/operations/continuous_integration.md` |

Failing-first record: the same suite run against `origin/main` (`86e80f1a`) before the change fails
five of nine scenarios (`daemon-restart-survives-follow`, `restart-window-expires`,
`gone-vs-unreachable`, `stale-supervisor-code`, `watcher-keeps-consuming`) plus the `undefined`
assertion in `follow-lost-wakes-a-watcher`; the four that pass are the incidents earlier fixes
already covered (#362 stall clock, #373 pin, `follow_lost` actionability).

## 5. Coordinator decisions (deliberately not implemented)

1. **Re-follow after a definitive loss.** A `follow`/`adopt` command that re-attaches a terminal
   `follow_lost` task to its session id without opening a new attempt. It adds a command and a
   state-machine edge (a terminal task becoming non-terminal) and must answer whether the attempt
   counter advances; it is a design change, so it is proposed with evidence rather than shipped.
2. **Alert when the daemon blocks, not when the CLI exits.** The supervisor is structurally one
   CLI-exit behind the daemon (20–171 s observed in run13) because `sanad run` publishes `running`
   → `retrying` → `failed` and never a `blocked` record; only the follower's probe can report one.
   Preferred shape: `sanad run` publishes `blocked` on its NDJSON timeline before exit — an
   additive Agent stream-contract change for the coordinator to approve. The alternative (polling
   the session while the worker is attached) is a worker/follower redesign.
3. **Delivery policy for the watcher.** `--linger-sec` gives the coordinator a watcher that
   consumes every alert; a supervised watcher process (launchd/systemd restarts `watch` when it
   exits) is the operational alternative if a long-lived call is undesirable.
4. **Restart window default.** `300000` ms is chosen to exceed a cold daemon start; an environment
   with a slower start can raise it per run without a code change.

## 6. Known limits

- A definitive `session_not_found` still ends the follow at the poll floor; the only recovery is a
  coordinator `continue` (new attempt) until decision 1 lands.
- `status` compares with the locally known `origin/main`, so an unfetched checkout under-reports
  staleness. It never fetches: a health read must not depend on the network.
- `--linger-sec` makes the watcher long-lived, not durable: a killed watcher still replays from the
  cursor on the next start, exactly as before.
