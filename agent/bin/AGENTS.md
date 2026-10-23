# Agent Entry Points Contract

## Scope
This contract applies to `agent/bin/`.

## Composition Ownership
- Entry points compose dependencies and select runtime mode; they must not own engine, protocol, persistence, provider, or capability business logic.
- Keep CLI, daemon, setup, service management, and supervisor concerns isolated behind focused commands and services.
- Service entry points accept one known action (or help); only install accepts bounded expected-version/cloud-health options. They delegate lifecycle and health decisions to `core/setup/`, present typed state, scope, backend, and concise errors without inferring installation from file existence, and propagate the operation result as the process exit code so installers and rollback scripts fail closed.
- Version and usage queries (`--version`, `-v`, `version`, `help …`, and `-h`/`--help` at any command level) and the read-only `service definition` report, as classified by `SanadCommandRunner.isPureQuery`, answer before Sanad Home preparation and must never create or write anything in `SANAD_HOME` or `SANAD_STATE_HOME`. A release or installer check that must prove Home preparation and bundled-skill extraction therefore uses a read-only non-pure command (`skills list`), never a pure query.
- No Home access before Home selection: an entry point resolves `--home` through the command layer's own resolver and applies it before Home bootstrap, the secret vault, skill sync, configuration seeding, supervision, or any other read or write under `SANAD_HOME`/`SANAD_STATE_HOME`. An explicit `--home` selects the complete Home (identity and state); a command line that does not parse touches no Home.
- The Agent vault opens only for a command that can read or write a secret, as classified per subcommand by `SanadCommandRunner.requiresSecretVault`: a gateway or local query (`session`, `workspace`/`ws`, `memory`, `schedule list`, `skills list`, and the pure queries) never opens it, and an unrecognized command line keeps opening it. A process that skipped the vault must never write a secret through a plaintext fallback (`SecretVaultPolicy.rejectPlaintextSecretMutation`).
- Every entry point applies `SecretVaultPolicy` before the vault opens. The daemon keeps the normal macOS Keychain authorization dialog at every entry point; a CLI process starts it only from explicit evidence of a person present (an interactive terminal, no machine-output flag, no supervisor), and otherwise forbids it, so an unattended caller never waits on a dialog it cannot show. A closed vault is reported through `sanad doctor`, an actionable daemon log line, and the local gateway `/health` `secret_vault` fields.

- Register local, cloud, and CLI platform adapters independently so one initialization failure does not prevent remaining interfaces from starting.
- Database retention work is scheduled only after durable restore, platform start, and the readiness signal; entry-point composition must not place cleanup or page-reclamation work on the startup critical path.

## Supervisor
- Daemon and service start paths run under the built-in supervisor in source and compiled deployments.
- The child-process marker is internal and must prevent recursive supervision.
- Controlled restart uses the daemon lifecycle endpoint and preserves checkpoint/exit semantics; direct termination is a timeout or unavailable-endpoint fallback only.
- Stop supervising after more than five child failures within fifteen seconds rather than entering an infinite crash loop.
- Daemon HTTP binding must preserve shared loopback bind behavior required for controlled supervisor handoff.
- Shutdown must terminate the active child cleanly before the parent exits.
- Source file watching remains disabled; runtime reload is explicit.

## Authentication Entry Flow
- CLI Headless login uses Portal Device Authorization from `Config.portalUrl` and never obtains User access/refresh credentials.
- Generate or load the Agent-owned P-256 key before starting. Send only its public JWK plus bounded device display metadata; never name providers.
- Display only the fixed verification URI, user code, and shortened JWK thumbprint. Keep device code and private key out of URLs, CLI arguments, stdout, logs, and telemetry.
- Device credential redemption requires fresh ES256 DPoP-style proof; Gateway reconnect requires a fresh server nonce signed by the same key.

## Configuration
- Setup removes non-ASCII/smart-quote corruption from imported credential keys before persistence.
- Local provider selection discovers local models without loading a model into VRAM; cloud setup may request the provider's dynamic model catalog.
- Setup delegates provider discovery/readiness to the core provider runtime.
- Entry points must not create repository-local configuration that competes with `SANAD_HOME`.
- Daemon startup must not require an LLM provider or credential. Provider readiness is checked lazily when a model operation is requested so local control, setup, and connectivity remain available after a clean install.
- Service/install/update mechanics belong to operations documentation and skills, not this contract.

## Oneshot Execution and Restart Resilience (`sanad run`)
- `sanad run` must follow its active turn across daemon restarts. When the gateway connection drops while a turn is in flight, the runner must not fail immediately; it enters a bounded reconnect loop governed by `--reconnect-timeout` (default 60 seconds).
- Reconnection discovery must remain bound to the selected Home's live endpoint (`LocalGatewayDiscovery`) and must never connect to an endpoint belonging to a different Home; a detected Home mismatch fails closed with exit code 78 (`home_identity_mismatch`).
- After reconnecting, the runner must inspect the durable session execution snapshot and compare its `request_id` with the dispatched request id, because a reclaimed turn keeps its work item and request lineage across the restart. On a match it re-subscribes to turn events and follows the turn to its terminal outcome, never re-submitting the brief and never admitting a second turn.
- The durable states that are still under daemon ownership are `running`, `resuming`, `waiting`, `queued` and `stopping`. `waiting` and `resuming` are non-terminal while the daemon owns automatic progress. `blocked` is never transient: the daemon schedules an automatic resume only for a `waiting` notice, so `blocked` keeps the documented exit 1 with `cause: blocked` and never becomes a silent wait until `--timeout`.
- A payload without an execution snapshot is never treated as proof that the turn was lost; the runner keeps following it rather than reporting a false `turn_lost`.
- A new `sanad run` invocation targeting an existing session whose durable turn still owns the session must refuse dispatch with exit code 3 (`turn_in_flight`) instead of interrupting or injecting duplicate input. A queued or parked (blocked) turn does not own the session and must not be refused.
- If the reconnect window expires before reconnecting or reclaiming the turn, the runner exits with code 1 (`reconnect_window_expired`). If the daemon returns but another turn now owns the session, or the turn finished with no recorded result, it exits with code 1 (`turn_lost`).
- Reconnect transitions must stay observable without noise: one stderr notice per lifecycle transition and one lifecycle event per transition (`reconnecting`, `reconnected`, `re_attached`, `refused`) on the run's event stream, with no per-poll logging.
