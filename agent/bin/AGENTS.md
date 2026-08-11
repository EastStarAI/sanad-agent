# Agent Entry Points Contract

## Scope
This contract applies to `agent/bin/`.

## Composition Ownership
- Entry points compose dependencies and select runtime mode; they must not own engine, protocol, persistence, provider, or capability business logic.
- Keep CLI, daemon, setup, service management, and supervisor concerns isolated behind focused commands and services.
- Register local, cloud, and CLI platform adapters independently so one initialization failure does not prevent remaining interfaces from starting.

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
