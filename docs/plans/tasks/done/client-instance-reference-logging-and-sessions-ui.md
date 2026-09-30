# Client Instance Reference in Agent Logs and Sessions UI

## Goal

Expose one privacy-safe, stable short reference for each authenticated Sanad Client instance in both Agent lifecycle logs and the Client's Sessions & Devices page, without changing the private Backend contract or logging raw Client instance identifiers.

## Scope

- Public repository only: shared Dart identity helper, Agent Local/Cloud log projection, and Client account-session presentation.
- Reuse the existing `client_instance_id`, `client_session_id`, Local `client.hello` metadata, and Cloud `origin_client` v1 projection.
- Keep detailed device model, browser/OS enrichment, friendly device names, and GeoIP location for a separate cross-repository plan.

## Gates

- [x] G1 — Define and test one canonical deterministic short-reference algorithm with instance-first and session fallback namespaces.
- [x] G2 — Agent logs distinguish Local/Cloud Client instances, preserve request/response correlation, and label multi-recipient delivery as `[clients]` without raw ids.
- [x] G3 — Sessions & Devices parses `client_instance_id` and renders the same short reference beside each Client session.
- [x] G4 — Update owning contracts, technical documentation, and QA coverage.
- [x] G5 — Run formatting, analyzers, focused Agent/Client/shared tests, diff checks, and Graphify update.

## Acceptance Criteria

- [x] Two Client instances of the same kind produce different short references.
- [x] The same Client instance produces the same reference in Agent logs and Sessions & Devices.
- [x] Local logs include normalized kind/platform when supplied by authenticated `client.hello`.
- [x] Cloud logs include normalized kind/platform from Gateway-authored `origin_client`.
- [x] Origin-scoped replies retain the originating Client reference; platform-family delivery is logged as `[clients]`.
- [x] Raw `client_instance_id`, `client_session_id`, custom names, email, hostname, IP, and command/event payloads never enter lifecycle logs.
- [x] Legacy sessions use a deterministic session fallback or neutral `client` label without inventing platform metadata.
- [x] No Backend, Portal, database, or deployment change is included.

## Evidence

- Shared package: analyze clean; `+4` tests passed.
- Agent: analyze clean; full suite `+1768 ~13`; focused Local/Cloud security suite `+45`.
- Client: analyze clean; focused suite `+12`; all tests except the Android signing repository guard `+1153`.
- The excluded guard fails only because the ignored local file `client/android/key.properties` exists; no signing material was read, moved, or changed.
- Graphify reported no topology changes; staged/unstaged diff checks and the bounded secret-pattern scan passed.

## Remaining

0% — all implementation, documentation, and verifiable acceptance gates are complete; the independent local Android signing guard exception is documented above.
