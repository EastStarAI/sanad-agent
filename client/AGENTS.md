# Sanad Client Contract

## Scope
This contract applies to `client/` and complements the workspace-wide contract with client-specific laws.

## Mission
Keep the client aligned with the thin-client architecture:
- feature-first ownership and clear presentation/domain/data boundaries;
- canonical conversation, device, provider, routing, and socket flows;
- tests updated with behavior changes;
- runtime authority deferred to the local agent rather than reconstructed in UI state.

Do not introduce convenience code that weakens these boundaries.

## Critical Architecture Boundaries

### Thin-Client Authority
- The agent is authoritative for execution, delivery classification, queue/steer/stop recovery, provider readiness, tools, MCP, skills, workspace runtime data, and agent-owned settings.
- Client state is a typed projection of authoritative runtime/cache events; widgets and cubits must not create competing runtime stores or infer daemon outcomes from presentation flags.
- Presentation never calls `SanadSocketService`, parses transport envelopes, reads agent-owned files, or selects local/cloud transport directly.
- Device-targeted work carries explicit device identity through repositories/clients and the shared connection coordinator.

### Device and Endpoint Ownership
- `DeviceCubit` is the sole presentation authority for the active conversation device. Settings inspection scope cannot change it implicitly.
- Desktop local inventory survives cloud logout, refresh failure, and cloud socket failure; web and mobile remain cloud-only.
- Cold start preserves a persisted cloud device while cloud inventory is pending, and a successful authoritative inventory clears a stale missing cloud id before fallback.
- Mobile/web cloud interruption, timeout, or `5xx/503` never implies logout. Keep the authenticated cached surface visible and stale/offline until authoritative inventory and active-history resynchronization succeeds.
- Local daemon health, lifecycle, update, socket, and voice endpoints derive from `AppConfig.localGatewayUrl`; never hardcode the production daemon port.
- Local Gateway access is desktop-only. Web and mobile remain remote-only and must never read a Local Gateway credential or attempt a local connection.

### Conversation Ownership
- `ConversationCacheStore` is the single client-side owner of conversation cache, device destinations, drafts, pagination resources, and workspace expansion.
- Conversation delivery, execution, attention, suspension, queue, steer, stop, replay, and recovery change only from matching authoritative outcomes.
- Session, draft, processing, and recovery state remain isolated by device/session identity; a selected session from another device cannot survive a device switch.
- Raw request id is transport identity. Display ids, timestamps, and optimistic UI rows cannot replace it.

### Provider and Configuration Ownership
- Provider templates, instances, credentials status, model options, readiness, defaults, limits, and failover settings come from the agent provider runtime.
- Provider setup remains instance-first; the client must not hardcode providers, synthesize instances, or treat cached models as readiness.
- Never expose raw access, refresh, polling, device, provider, or recovery-owner credentials in logs or UI state.

## Development & Testing Requirements
Before concluding any task or development iteration in `sanad-agent/client`, choose verification based on the blast radius of the change:
1. **Run Static Analysis:** `fvm flutter analyze` for all code changes.
2. **Run Targeted Unit/Widget Tests:** Run the focused `fvm flutter test ...` command covering the changed behavior.
3. **Run the Full Fast Suite When Risk Warrants It:** Use `fvm flutter test` for broad UI/state/data-layer changes or when the touched code is shared across multiple features.
4. **Run E2E Only When Required By Scope:** `fvm flutter test e2e_test/` is required only for changes that affect real socket behavior, local daemon connection states, app/bootstrap runtime integration, worktree port/runtime isolation, or client/daemon contracts. E2E is intentionally expensive and must not be treated as mandatory for isolated UI, widget lifecycle, formatting, copy, or pure unit-level changes.
5. **Isolate Daemon-Backed E2E State:** Every spawned E2E daemon must receive a unique temporary `SANAD_STATE_HOME`, clean it after shutdown, and use the deterministic E2E provider. Tests must never inherit the live agent database or invoke the user's configured provider.

When interface or runtime ownership changes affect the local daemon contract, prefer adding or updating a real daemon-backed test under `e2e_test/` instead of relying only on mocks.

## Definition Of Done
1. Follows all ownership, layer, and directory boundary rules.
2. Relevant tests are added or updated.
3. Analysis (`fvm flutter analyze`) passes without errors.
4. Targeted tests covering the changed behavior pass.
5. Full fast-suite and E2E results are provided only when the change scope requires them under the testing requirements above.

## Boundary Ownership
- Keep infrastructure-specific transport laws in the infrastructure domain.
- Keep feature-specific runtime laws in the nearest owning feature contract; do not duplicate them in this client-wide contract.
