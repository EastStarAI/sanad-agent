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
