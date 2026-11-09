## 1.0.22

- Added dictation to the Agent daemon: one pipeline served by a `/ws?type=dictation` local channel beside the untouched voice path and by the hosted `dictation_relay_v1` capability with request/route/seq identity, binary PCM framing, origin-only delivery, admission limits, and TTL cleanup, both sharing one `DictationService` (lease, engine, residency, vocabulary); a dictation session never creates a conversation session, session identity, or client tag, and voice origin correlation is unchanged (#337).
- Gave the model catalog identity instead of copy — `name`, a `{en, ar}` description, `badge`, `speed_tier`, `size_bytes`, `streaming`, and `location` — plus install/verify/activate over a verified per-platform-tag `agent-runtime` archive and readiness that resolves the model a session would load, so `stt_status`, the settings projection, and a session start report the same `model_not_installed` or `sherpa_runtime_missing` instead of a session the daemon then refuses (#337).
- Made a native runtime failure disable dictation only: `release/contract/lib/src/native_runtime_install.dart` owns the `.runtime-install-failed` marker, a closed cause vocabulary (`runtime_download_failed`, `checksum_failed`, `trust_failed`, `layout_rejected`, `replace_failed`, `install_failed`), and the readiness reason `native_runtime_install_failed`; the bundle, updater, and both installers warn, restore the predecessor runtime when they can, record the cause, and exit successfully, `AgentUpdateStatus.runtimeFailed` is removed as unreachable, and an unverified library is still never extracted or loaded (#337).
- Packaged the engine inside the runtime archive under `native/<tag>/sherpa/<library>` with loader-relative paths the library appends, which also fixed a defect on every platform: `initBindings()` with no path only worked in a developer checkout, so a packaged Agent could never load sherpa (#337).
- Published the Agent for Linux arm64: an `ubuntu-24.04-arm` lane builds, smokes, and archives `sanad-agent-<v>-linux-arm64` in the same matrix and trust policy as Linux x64, `requiredAgentReleaseTargets` is the single declaration of the official Agent matrix that `validate-contract` and release preparation enforce, and `scripts/install.sh` now reaches a real artifact on an aarch64 host instead of stopping at a name that did not exist (#359).
- Resolved the installed Home before the account default: `getSanadHome()` returned `$HOME/.sanad` when `SANAD_HOME` was unset, so every service command in the root-install unit (whose `sanad-agent` account has the Sanad Home as its passwd `$HOME`) looked in a second, empty Home and reported `Failed` or `Service exists without Sanad ownership metadata`; the installed binary and unit now decide the Home, the account default is only the fallback, and no second `.sanad` tree is created (#365).
- Bounded daemon memory retention and removed quadratic streamed-text accumulation: content, thought, and reasoning accumulate in `StringBuffer`s that are materialized once instead of rebuilding the answer per delta, the history snapshot cache is bounded by retained text (32 MiB) as well as by session count, and a channel-scoped response emitter is released with the channel that registered it instead of pinning a closed Client socket per session for the process lifetime (#369).
- Projected every durable runtime notice instead of only the live broadcast: `session.query` now projects every non-`cleared` notice with its wire vocabulary and widened recovery actions, `retry_attempt`/`retry_budget` persist as additive nullable columns that survive a restart, and `session retry` classifies with the same `RuntimeRetryState.fromProjection` that `session show` uses, so a scheduled automatic retry is readable, retryable, and journalled as one `retrying (n/N)` record instead of `progress_stall` (#372).
- Stopped the daemon from waiting on, or prompting for, the OS secret vault: the daemon decision is `forbidden` (`daemon_background`), the CLI entry opens no vault when it dispatches to a daemon, the vault opens off the startup path through `beginOpen()` with a bounded never-throwing `readyWithin`, `vault_not_ready` replaces a read reported as an absent value, `/health` publishes `secret_vault: opening|available|unavailable`, and one WARNING line per start states what is unreadable plus the `sanad vault authorize` recovery route (#370).
- Routed recovered session titles through the session provider: after a restart every recovered session logged a 404 model-not-found title failure and fell back to the user message, because title generation used the raw model id instead of the resolved provider route; recovered titles now resolve the same route the session itself uses (#368).
- Announced session deletion to every Sanad client: `delete_session` produced one `session_deleted` envelope stamped `DeliveryPolicy.origin`, so a connected Client kept showing a conversation deleted from the CLI until it restarted; deletion now also publishes through `GatewayManager.publishFamilyEvent` (#364).
- Kept a run session's mode and permissions from creation: a `session_created` projection built only from the registered workspace carried no `workspace_id`, `execution_root`, or `permission_mode`, a Client message into an existing run session omitted `allow_all_tools` and reset it to `false`, and the picker wrote to the workspace policy instead of the session's own override; turn targeting now seeds the created session, a turn that keeps its targeting inherits the session's durable authority, and the new `set_session_permission_mode` command writes the session's own override and republishes the full payload (#351).
- Added health columns, a removal verdict, and confirmed pruning to `sanad-dev inventory`: bounded disk size, last-commit age, upstream state, and an opt-in cached `--pr` lookup behind one `safe`/`keep` verdict with the first blocking reason, JSON schema 2 additive, and a new `cleanup-orphans` that is dry-run by default, deletes only strictly inside `<primary home>/dev` with `--confirm`, and refuses the primary Home, a Test Home, a group directory, a symbolic link, and any live runtime (#363).
- Taught `sanad-dev ui` long press (`--hold-ms`), in-app hover, allowlisted extension calls (`ext.sanad_client.*`), obscured-target reporting, and tooltip text, all inside the Client's own pointer pipeline so no command needs window focus or an accessibility grant (#366).
- Kept the Web Client signed in across Chrome restarts by giving the browser a persistent profile per Test Home instead of flutter_tools' throwaway per-launch profile, so Portal access/refresh, device id, and client instance id survive (#374).
- Measured supervisor stalls from real progress instead of a busy slot: `lastProgressAt` now advances on a task's timeline, stdout, stderr, or result artifact, `queued_stall` is a real defect again instead of every task waiting for a slot, and the daemon's stated retry deadline extends the silence clock so a scheduled retry is not reported as a stall (#362).
- Pinned the daemon session a `continue --new-session` attempt opened, so a later plain `continue` returns to the conversation the operator expects and `status`/`inspect` name the continuation target (#373).
- Announced Stable releases after Production assets deploy: the Discord workflow now subscribes to the completing release run, refuses unless every serialized Production asset job succeeded in that same run, resolves only the Release that run published, and records an announce-once ledger so a re-run cannot repeat it (#360).
- Added a read-only post-release Production surface verifier that compares every version-bearing public surface with the newest published Stable release, reports an open release window instead of failing while the newest release is still a Draft, and sends `no-cache` requests with no per-release marker so a stale intermediary is a finding instead of something routed around (#358).
- Renamed the three committed agent-state fixtures to `*.sql.txt` and added a guard that fails on any tracked path whose final component ends in a deploy-rejected suffix, so a committed fixture can never block a private Production deploy again (#361).

## 1.0.21

- Made provider discovery report a rejected credential instead of its raw body: `ProviderDiscoveryError` carries a category, HTTP status, canonical reason, and an endpoint reduced to `scheme://host[:port]/path`, the structured form persists in `provider_model_cache.last_error_detail` beside the sanitized one-line `last_error` and both are nulled by a verified re-discovery, `401`/`403` now report `needs_auth` instead of `draft`, and `provider.instance.test` requires a verified live discovery plus one minimal generation probe shared with setup verification and the CLI (#346).
- Kept Codex prompt-cache affinity across Responses hosts with a bounded content-addressed `prompt_cache_key` mirrored in the ChatGPT affinity headers for sync and stream, kept for xAI and dropped only for GitHub-hosted Responses endpoints (#356).
- Exempted `run` from the eager secret-vault open: a gateway run attaches to the daemon that owns every credential and `--standalone` already opens the vault lazily, opening the vault still clears the skip decision so a standalone run can write/remove/prune, and the AOT smoke proves a gateway turn completes with no `secret_vault*` artifact in a throwaway Home (#350).
- Let `sanad run` follow its turn across a daemon restart: it spends up to `--reconnect-timeout` rediscovering the same Home (a foreign Home still fails closed with exit 78), re-attaches by comparing the durable execution snapshot's request id with the one it dispatched, and finishes with that turn's real outcome instead of `Gateway connection lost before turn completed`; `--session` against a still-owned turn refuses with `turn_in_flight` (exit 3) (#278).
- Stopped publishing an already-scheduled automatic retry as `blocked`: `RuntimeNotice` carries `retry_attempt`/`retry_budget` with `isAutomaticRetryPending` and `awaitsIntervention`, a scheduled retry publishes `waiting`, `blocked` strictly means nothing continues without an operator, and `sanad session show` derives status from the durable execution state rather than a stale `in_flight` projection (#297).
- Made `sanad models` report the stored `thinking_control` descriptor — status, options, effective default, and deciding authority — in the human block and the `sanad.models.v1` `--json` document, additively, with `unsupported` and `unknown` stated honestly instead of as an absent badge (#279).
- Fixed automatic compaction for oneshot sessions: continuity anchors now own their line (start, optional markdown prefix, colon directly after the label) so `ask:` no longer matches inside `Task:` or `## Blocker:`, values over 160 characters are report-only, every label maps to one schema field, a repeated summary object decodes from its leading balanced object, and a failed automatic compaction records one durable `warning` notice that a later success clears (#352).
- Added `evolution/db/sqlite_transaction.dart` as the one write-transaction boundary so nothing issues a bare `ROLLBACK` after SQLite already aborted a transaction, added the typed `RuntimeFailureReason.storageFull` that publishes `Storage full` without a provider body and never retries or fails over, and bounded request dumps with the new `diagnostics.requestDumpRetentionDays` policy (default 3 days) enforced by a single sweeper (#354).
- Made a root Linux install usable: install.sh selects `/var/lib/sanad-agent` as the Home (an explicit `SANAD_HOME` still wins and an already-installed root Home is kept), one shared `service_account_policy.dart` rule decides the unit account for every root entry point including sudo, `sanad service install` preflights `ExecStart`/`WorkingDirectory` as the unit's own account and refuses before staging, `--run-as-user <account>` is the one explicit override, a conflicting existing unit stops the install with exit 71 and the removal command, and `ServiceHealthVerifier` counts real attempts and names the missing credential (#344).
- Added schedule state columns, the run table, and repositories; scheduler control with typed refusals, the run recorder and observer that write `running` before dispatch, record `skipped`, reconcile `interrupted`, and flag `suggest_pause` after three failures; `pause`/`resume`/`run_now` and an optional `name` on the `schedule_task` tool; and the protocol commands, queries, and events the Client renders (#312, #317, #321, #325).
- Delivered scheduled work as its own turn with `delivery_intent='queue'` instead of a mid-turn steer, kept one conversation for a `continuous` schedule by re-reading the row at dispatch, and exposed the `history:<sessionId>:<rowId>` anchor in `schedule.runs` (#321, #329).
- Gave user secrets a write-only protocol and storage layer: metadata and catalog with an acquisition hook that records where a value came from, `secrets.list`, `secret.set`, `secret.delete`, and `secrets.changed`, with no read command (#315, #318).
- Synced the `sanad-client` relay grammar with the Agent's `--reconnect-timeout` and `--run-as-user` value options so both sides resolve the same session for the same argument vector (#284, #355).
- Added `sanad-dev inventory [--all] [--json]` as one read-only projection of worktrees, runtimes, Clients, Test Homes, and orphans with the exact cleanup command for each, and cut the fixed cost of a warm `sanad-dev ui` invocation (#281, #274).
- Taught the delegation supervisor to follow a daemon-owned turn after its worker exits (`following`, mirrored `needs_input`/`needs_permission`/`blocked`/`waiting`/`resuming`, the turn's real outcome with an explicit result source) and to spawn each worker as its own process-group leader so a cancel reaches the real process (#267, #280).
- Sharded Agent and Client tests, parallelized independent checks, and cached the toolchain so workflow wall time fell from 607 to 265 seconds; moved protected review-label verification to an on-demand dispatch; and serialized the Production asset jobs as `updates` → `web` → `installers` with bounded fail-closed verification (#348, #347, #277).
- Split the largest single-responsibility modules — supervisor, session, workspace, provider, state, and configuration — with characterization tests and schema snapshots that pin the previous behavior, and removed the size-ratchet allowlist entries the splits retired (#285–#320).

## 1.0.20

- Stopped opening the Agent secret vault for commands that read no secret, ending the compiled-CLI hang on an invisible macOS Keychain prompt: the per-subcommand classifier covers `session`, `workspace`/`ws`, `memory`, `schedule list`, `skills list`, and the pure queries, a skipped vault refuses `write`/`remove`/`pruneOrphans` instead of falling back to plaintext, and prompt ownership is decided once from explicit evidence so the daemon and an interactive terminal invocation may prompt while `--json`, `--quiet`, and `--child-process` fail closed (#271).
- Bound every Home-selected command to that Home's own local gateway endpoint and token: the daemon publishes an owner-only `.local_gateway_endpoint.json`, discovery verifies the answering `home_id` before sending a credential, `--home` ignores inherited gateway variables, `.local_token.home` binds the token to its Home, and a missing, stale, foreign, unreachable, or mismatched runtime fails closed with exit code 78 (#268).
- Let the forced-standalone ownership pre-check select its probe deadline by probe scope again, sharing one run-scoped discovery instance with mode resolution, so a healthy daemon answering slower than the speculative bound is no longer read as absent (#264).
- Signed the macOS Agent with the stable identifier `com.eaststarai.sanad.agent`, asserted the identifier and designated requirement in the signing step, and guarded both plus the team OU in the `release-security` CI job (#272).
- Made `sanad-dev ui` reuse a cached native artifact instead of compiling per action, added per-action deadlines with bounded exit 124 diagnostics, `wait-for`, snapshot `generation`/`signature`, verification options in batch steps, and removed the dead Flutter Driver fallbacks except `screenshot` (#266).
- Recorded Task 78's completed live acceptance and merge in its task record (#265).
- Added `sanad session steer <session-id> (--message <text> | --message-file <path>)`: it dispatches one `steer` with `steer_only: true`, so the daemon answers a steer with no live owner as one typed `no_active_turn` rejection (exit 3) instead of admitting or queuing it, keeps the durable execution snapshot — not a stale `in_flight` projection — as the fast-path test, separates `admitted_as_turn` (6), `queued_as_turn` (7), `steer_not_applied` (4), `steer_unacknowledged` (5), and `session_state_unreadable` (8), and reports only a gateway acknowledgement of that message id; the steer body never reaches stdout, stderr, or logs (#269).
- Added `sanad session retry <session-id> [--provider <instance-id>] [--model <model-id>]`, which sends the Client's own `session.runtime_retry` after refusing any session whose recovery notice and durable snapshot are neither `blocked` nor `waiting` (`not_blocked`, exit 3), reports the daemon's `resuming` transition, and keeps `retry_rejected` (4), `retry_unacknowledged` (5), and `session_state_unreadable` (8) distinct (#269).
- Stated the automatic-retry outcome in the terminal blocked notice — `Automatic retry gave up after N attempts; retry manually or choose another provider.` or `No automatic retry: the response had already started streaming.` — so a worker whose per-reason budget was already spent no longer waits behind a notice that reads like a first failure (#269).
- Made the `sanad-client` relay approval resolve its target session with the Agent's own argument grammar and refuse an argv that names two different sessions (`ambiguous_session_target`), backed by `agent/test/fixtures/cli_relay_grammar.json` generated from `SanadCommandRunner` and asserted from both the Agent and Client sides (#269).
- Made workspace resolution read-only for every daemon caller: a path resolves to the supplied id, the exact stored path, the innermost registered workspace whose root contains it, and otherwise its synthetic `exec_root:` identity, so a `workspace.get_policy` query for an execution root no longer registers a workspace named after that folder, and the `legacy_path_request` fallback is gone while `workspace.create`, the Client picker, managed remote create, and Change Path still write rows (#275).
- Added the `sanad-dev` runtime tooling layer for worktree development: `reset` with per-Home staging, a per-Home lock, rollback and crash recovery behind an allowlisted fixture that never reads secrets, a per-commit compiled CLI cache (`sanad-dev cli`), an `apply` decision table that executes the lightest correct action and records a per-path baseline so a revert, deletion, or second edit is reported without repeating an applied one, a one-shot self-deleting `refresh --at`, and report-only `doctor` driver-host checks read through passive `dart:ffi` preflight calls (#270).
- Made `sanad models` report the thinking capability the daemon resolved for each route: the cached descriptor's `status`, options, default, and winning authority `source` now reach both the human block and the `sanad.models.v1` `--json` document, so a route's real levels are readable from the CLI instead of only through the Client snapshot or `state.db`, and an `unknown` route is stated honestly rather than as an absent badge (#137).

## 1.0.19

- Applied `sanad models --provider/--model`, added a `sanad.models.v1` `--json` document, and failed closed on unknown or ambiguous selectors (#261).
- Added `sanad run --no-stdin` so shell read loops keep their input (#261).

## 1.0.18

- Released the session queue after a pre-start turn refusal, reported one clean reason line, ended `sanad run` at once when the daemon blocks a turn, and waited for the real outcome in `sanad session compact` (#253).
- Made `sanad session stop` confirm authoritative idle state before reporting success, release the owner's in-flight projection and suspended checkpoints, name the addressed run, and stop `sanad session show` reporting stale `running` (#259).
- Added remote `sanad-client` delegation through a canonical `device.cli.execute` relay with streamed output, cancel forwarding, one CLI owner per Sanad Home, and `default`/`full_access` approval (#188).
- Hardened the relay: the window follows `--timeout`, background runs stop consuming stdin, pending approvals are announced, and a run without a terminal result exits 1 instead of reporting success (#256).
- Ported execution trust, command authority, and secret isolation: daemon-private workspace policy, per-turn command authority, exact child environments, closed `.env` redaction, and localized Full Access confirmation (#245).
- Added interactive secret acquisition with an owner-only value-free boundary, explicit `shell_execute` secret injection, and request/list/delete tools (#246).
- Added `sanad skills list|add|remove|update` with provenance, collision protection, and content screening (#220), plus skill-declared `allowed_remote_exec` installer hosts (#222).
- Added recurring schedules behind one `schedule_task` tool and made `sanad schedule list` a real read-only listing (#240).
- Confined the remote workspace picker to `<SANAD_HOME>/workspaces` with Agent-enforced path validation (#239).
- Supported multi-chunk atomic `file_edit` with pre-validation, overlap detection, and preserved line endings (#216), and added typed text/image tool results with `view_image` (#201).
- Reworked compaction onto a whole-request target with a pre-send fit check (#247), bounded passes and hardened failed summaries (#236), reconciled stale startup locks and calibrated token estimation (#210), and reported truthful manual compaction feedback (#228).
- Preserved pending user-input waits across managed stop and abrupt restart (#215), kept history identity on in-place rewrite with bounded recovery summarization (#233), and made terminal classification session-scoped with durable stamps (#238).
- Kept fork markers and auto-failover notices at their causal position on every reload and history page (#241).
- Projected each request into the destination provider's wire form (#232), dispatched OpenCode Go models on their per-model protocol (#234), and replayed an empty `reasoning_content` for same-route thinking tool turns (#251).
- Reported update trust stages with installer guidance, added read-only `sanad service definition`, and made version/help queries pure (#242).
- Applied `--home` before any Sanad Home access so an explicit Home can no longer be bypassed (#249).
- Passed non-ASCII shell arguments intact on Windows via UTF-8 code page 65001 and reported `exit_code` from `shell_execute` (#255).

## 1.0.17

- No Agent runtime changes; aligned the shared release version with the Client account-deletion patch (#204).

## 1.0.16

- Preserved interactive user-input waits across managed daemon stop (#196).
- Added provider-aware thinking mode and route controls in the agent engine (#194).
- Resolved local model context limits and compaction safety (#193).
- Tracked tool execution timing and exposed duration_ms in shell_execute (#192).
- Self-healed stale runtimes and enforced deterministic process identity (#191).
- Enforced result data fidelity and semantic terminal validation (#190).

## 1.0.15

- Prevented redundant capabilities fetching and restored sidebar hover trigger (#186).

## 1.0.14

- Ensured appearance synchronization works across both local and cloud gateway transports (#183).
- Guarded PlatformRuntimeBridge resolution in LocalDaemonServerPlatform against test teardown GetIt race (#184).

## 1.0.13

- Hardened child process test execution timeouts and CI latency tolerance for constrained virtual runners (#181).
- Resolved symbolic links on temporary test directories for macOS runtime parity (#179).

## 1.0.12

- Resolved symbolic links on temporary test directories for macOS runtime parity (#179).

## 1.0.11

- Added native `sanad run` CLI delegation with OpenCode compatibility and automatic session recovery (#148, #149, #150).
- Raised default context-compaction threshold to 90% and hardened model context limit resolution (#163).
- Hardened agent state database concurrency and added automated database maintenance (#153).
- Added Windows-first headless background daemon launching without console allocation (#156).
- Implemented local turn request deduplication and concurrent turn serialization (#168).
- Reduced long-session turn startup latency and improved child process execution safety (#168).

## 1.0.10

- Added account session and device lifecycle management with secure remote revocation and immediate cross-transport disconnect.
- Added cloud delivery presence and device-interest coordination so Local and Cloud routes remain isolated and authoritative.
- Added authoritative command-origin propagation and stable Client instance identity across reconnects.
- Improved multi-runtime development, source-runtime ownership, and automated macOS/Web/iOS validation.

## 1.0.9

- Added provider-backed multilingual context compaction with typed JSON validation and bounded recovery (#139).
- Propagated causal turn, run, and step IDs across live execution events and anchored steering messages to durable tool-call references (#142).
- Added session affinity headers for OpenCode requests (#140).
- Added canonical application attribution headers for OpenRouter requests (#141).

## 1.0.8

- Added revision-matched provider catalog context-window resolution for newly discovered models and prevented compaction failure when no source head is available (#136).

## 1.0.7

- Added durable conversation replay, materialized forks, paginated history, and synchronized live-history recovery (#125, #127, #128, #131).
- Added run-scoped cancellation, safe forced-shutdown recovery, and protection against replaying active provider requests after controlled restart (#112, #117, #124).
- Added durable model-aware context compaction and contained provider model-refresh failures (#118, #123).
- Added secure device-scoped workspace and MCP control plus durable Linux headless Agent installation (#120, #121).
- Hardened `sanad-dev` runtime ownership, background startup, and multi-driver control (#126).
- Added deterministic release identity preparation and fail-closed metadata verification (#132).

## 1.0.6

- Hardened macOS Agent runtime trust verification to enforce Developer ID publisher requirements (#105).
- Strengthened installer pairing contract guards and release manifest verification (#105).

## 1.0.5

- Upgraded macOS Keychain backend to Apple `SecItem` API, sanitized auth storage serialization, and automated CLI PATH configuration (#102).
- Serialized concurrent Agent permission prompts per session to prevent approval race conditions (#99).
- Added Flutter VM driver CLI for automated UI diagnostics and testing (#98).
- Updated macOS release CI runner to macos-26 for Xcode 26 support (#101).

## 1.0.4

- Corrected the Windows release smoke gate so PowerShell uses a writable Sanad Home variable instead of the reserved `$HOME` variable.
- Supersedes the unpublished v1.0.3 candidate; no v1.0.3 GitHub Release or Production asset was created.

## 1.0.3

- Replaced transferable OAuth polling with S256 PKCE for Client sign-in and P-256 proof-bound Device Authorization for headless Agents.
- Bound one-command pairing and Gateway registration to fresh key-possession proofs, with vault-backed Agent credentials and fail-closed legacy-token rejection.
- Added verified mobile callback ownership, safer runtime recovery, external-workspace permission gates, and the latest Client navigation and interaction improvements.

## 1.0.2

- Serialized native desktop authentication and token refresh with cross-process OS file locks (`shared/auth_lock`).
- Hardened `sanad-dev switch` runtime handoff to automatically prepare target checkout workspaces.
- Synchronized release manifest contract and version definitions with Client 1.0.2+3.

## 1.0.1

- Hardened Sanad Home, Local Gateway, authentication, and remote-management boundaries.
- Improved session recovery, provider setup, workspace handling, and typed tool history.
- Completed verified desktop Client-Agent installation, update, and rollback lifecycle.
- Added form-first MCP server configuration with runtime isolation.

## 1.0.0

- Initial version.
