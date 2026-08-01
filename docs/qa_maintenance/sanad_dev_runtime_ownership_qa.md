---
title: "sanad-dev Runtime Ownership QA"
description: "Regression matrix for managed launcher ownership, reconciliation, clone isolation, and continuous source handoff."
---

# sanad-dev Runtime Ownership QA

## Regression matrix

| Scenario | Expected result |
|---|---|
| Primary checkout, no contradictory active owner | User Home and canonical primary endpoint behavior remain available. |
| Linked worktree | Home, agent port, VM-service port, and preferences are isolated. |
| Independent clone while another workspace owns the primary endpoint | Run and dry-run fail closed and request an absolute Home; no process or runtime state changes. |
| Independent clone with an absolute Home | Home and preferences derive from the override; agent and VM-service ports use workspace-hashed isolation. |
| `LOCAL_GATEWAY_PORT` or `LOCAL_GATEWAY_URL` inherited from another runtime | Ordinary status, stop, and developer discovery ignore it and select by workspace hash. |
| Status with an explicit supported port | The endpoint is selected for diagnostics but foreign clients remain cross-owned and non-mutable. |
| Client source matches but gateway agent belongs to another workspace | Status labels it cross-owned; run does not recommend stop; stop refuses the complete operation. |
| Client launch profile is missing | Client is unverifiable and stop refuses before signaling anything. |
| Client Home, preferences, workspace hash, gateway, or source is contradictory | Client is unverifiable or cross-owned and the complete stop preflight fails. |
| Client/Agent fields agree but no live launcher lease exists | Group remains manual and ordinary mutation is refused. |
| Healthy launcher lease, available Agent identity, and exact active Client nonce/PID/VM set agree | Complete, Agent-only, and Client-only runtimes remain managed; repeated component run is idempotent. |
| `run all -d macos` from a stopped runtime | Agent and Client spawns begin without readiness ordering; both identities must verify before the lease reports running. |
| Client exits while Agent remains active | Launcher removes only that Client from the lease and continues supervising the Agent. |
| Agent exits or is paused while Clients remain active | Launcher keeps Clients and the lease alive; status reports Client-only and a later `run agent` rejoins the same group. |
| Launcher PID is absent or its process-start/command identity changed | Runtime is orphaned; mutation fails closed. |
| Launcher flag or nonce differs on Agent/client | Runtime is orphaned or unverifiable; copied flags cannot establish ownership. |
| Component `run`/`stop` targets a managed group | A nonce-bound component request goes to the existing launcher; helper discovery does not signal child PIDs. Failure/timeout is nonzero and never prints success. |
| Resumable Agent shutdown reaches a safe checkpoint | The response is flushed, the source supervisor exits permanently, `requestStopAll()` is not called, and startup recovery retains non-terminal work. |
| Resumable Agent shutdown times out on an unsafe blocker | The drain is cancelled, the daemon remains running, and no Client or durable work is mutated. |
| Forced Agent-owning shutdown | Active and queued work receive bounded terminal cancellation before permanent exit and cannot resume on the next start. |
| `stop client -d macos` with one exact owned match | Only that Client exits; Agent work and sibling Clients remain active. |
| `stop client -d macos` with zero or multiple matches | Selection fails closed and lists diagnostic device/VM selectors without signaling a process. |
| `stop client --force` | CLI rejects the misleading combination as a usage error. |
| `doctor` | Reports class and ownership evidence without mutation. |
| `doctor --fix` with no launcher, Agent, or client | Removes only the stale/invalid record and signals no process. |
| Complete manual pair | `takeover` uses a safe Agent drain followed by permanent supervisor shutdown, relaunches it as one managed group, and attempts restoration on launch failure. |
| Incomplete/manual pair or Agent-origin takeover | Takeover refuses before client mutation. |
| Target orphan attached to requester/source port | Cleanup refuses before signaling any PID. |
| Target client has a live Agent/launcher, IDE ownership, or incomplete nonce | Cleanup refuses. |
| Proven target-only stale clients | Only exact recorded target PIDs are signaled and their stale record is removed. |
| Linked worktree has no runtime while primary is active | Output is `No active sanad-dev runtime found` for the linked worktree; primary is not selected or affected. |
| Completed source handoff record is displayed | Status says `Last source switch: complete`, making its historical nature explicit. |
| Source switch changes source workspace | The client workspace hash and readable source markers change together; retained Home and endpoints remain valid. |
| Agent-origin target switch succeeds | The original tool result is `complete`; no follow-up status call is required. |
| Target startup fails and previous group is healthy | Original tool result is `rolled_back` and the same durable session resumes. |
| Target and restoration both fail | Original tool result is `recovery_failed`; continuity is not claimed. |
| Safe drain/preflight fails | Original tool result is `failed`; source processes remain intact. |
| Recovery repeats after terminal result persistence | The switch is not replayed and the original result is not duplicated. |
| Health discovery | HTTP contains hashes, abstract modes, and launcher correlation tokens only; never absolute source or Home paths. |

## Bootstrap, journal, and terminal matrix

| Scenario | Expected result |
|---|---|
| Fresh POSIX or Windows user environment | FVM verification precedes Flutter, Agent dependencies, Client dependencies, and shim installation; `run all` begins only after every stage succeeds. |
| Windows bootstrap starts outside a Git checkout but beside its copied project scripts | The non-repository Git probe is handled without a raw PowerShell native-command error, and bootstrap continues from the script-owned project root. |
| Journal crash fixture exits nonzero on every host | A hermetic platform-native fixture avoids package-runner exit-code differences and captures stdout, stderr, and crash-like stack output after exit. |
| Windows bootstrap uses an isolated user root in CI | Its fake command surface includes deterministic file hashing, so redirected user paths cannot depend on ambient PowerShell module discovery. |
| Unchanged second setup | Pinned Flutter and dependency stages are skipped when SDK, lockfile fingerprint, and package configs agree. |
| Flutter pin or either lockfile changes | The stamp invalidates and the affected setup sequence runs before runtime launch. |
| Existing shim belongs to another checkout | Setup fails without replacing it; `setup --force` performs the explicit replacement. |
| No arguments | Setup completes, then the wrapper invokes `run all`; explicit `setup` exits after preparation. |
| Default or overridden source profile | Default is Production with Cloud enabled; `--no-cloud` disables hosted routing; `--config config/dev.json` remains explicit. Tests use constants/fakes and perform no hosted request. |
| Agent emits logger, print, stderr, or an uncaught stack before health | All bytes remain in bounded history after process exit and are available to follow readers. |
| Client emits Flutter build output, logger/debug output, print, stderr, or uncaught stack before VM readiness | One Client journal preserves the output in arrival order and its watcher can start before VM discovery. |
| History transitions to follow while output is written | Snapshot offsets prevent gaps and duplicate replay. |
| Caller candidate Agent port differs from a live Client gateway | Client logs derive Home/Agent journal identity from the selected Client launch profile and do not fall back to the VM logger. |
| Journal exceeds segment limit | Monotonic rotation retains at most four 2 MiB segments; stale journal cleanup and owner-only permissions apply. |
| Agent restart or source handoff | A generation marker separates output while the same Agent log surface continues. |
| Manual runtime logs | Existing HTTP/VM fallback works and explicitly disclaims unavailable process/build history. |
| Interactive `run all` | Current terminal mirrors Agent; one independent watcher opens for each Client. |
| Add or close a second Client | A second watcher opens; closing that Client closes only its watcher and does not affect Agent or siblings. |
| macOS, Linux, and Windows terminal quoting | Adapter arguments preserve paths with spaces/quotes and never transfer child ownership. |
| Headless execution or terminal launch failure | Runtime success/ownership is unchanged and a bounded copyable log command is printed. |

The required CI matrix runs bootstrap, journal, profile, and quoting tests on
macOS, Linux, and Windows. It resolves package dependencies but does not launch a
cloud-connected runtime or send credentials/fixtures to Production. Live
Production cloud smoke remains manual and optional.

## Hermetic test boundary

Ownership tests construct fake agents, clients, launch profiles, Homes, paths,
lease records, process identities, and endpoint numbers. Stop behavior receives
an injected launcher-request transport; target cleanup receives an injected
terminator. Tests assert fake calls and never invoke real process termination
or a user-owned endpoint. SQLite-backed Agent tests persist a deferred
descriptor, resolve a terminal manifest once, and verify the completed original
tool result is reused.

Daemon-backed handoff tests must allocate a temporary Home and non-primary
ports. They cover one successful target start and one forced target failure
with verified rollback. Real source-switch, restart, stop, or standalone-clone
launches against the developer's active runtime remain prohibited.
