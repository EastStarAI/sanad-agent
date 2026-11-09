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
- Account lifecycle list/revoke/delete uses one application-scoped repository over the authenticated Cloud Socket; Portal HTTP owns OAuth/refresh/logout but no lifecycle routes. Profile Page owns the confirmed account-deletion action; deletion permanently removes cloud account data while strictly preserving local Agent files and conversation history. Observation is consumer-lazy: opening Sessions & Devices fetches, a closed page never fetches on auth/reconnect, and an open disconnected page retains a stale snapshot until one coalesced reconnect refetch.
- Device-targeted work carries explicit device identity through repositories/clients and the shared connection coordinator.

### Render and Request Independence
- Widget builds, builders, layout/theme changes, window resizing, and responsive subtree remounts must not initiate Agent data requests, directly or through build-scheduled post-frame callbacks. Rendering is side-effect-free.
- Logical resource owners, not widget lifetimes, own fetch admission, in-flight deduplication, freshness, and authoritative invalidation. Mount/rebuild of another consumer of the same unchanged resource is not a new fetch intent.
- Valid user intent, logical device/resource changes, and authoritative invalidation/reconnect may request data through the owning layer. Deduplication must preserve device/query scope and must not drop necessary events, suppress legitimate refreshes, or present stale data as current.
- Changes to responsive UI must retain regression coverage proving that resize/rebuild alone emits no extra Agent fetches for unchanged logical resources.

### Device and Endpoint Ownership
- `DeviceCubit` is the sole presentation authority for the active conversation device. Settings inspection scope cannot change it implicitly.
- Desktop local inventory survives cloud logout, refresh failure, and cloud socket failure; web and mobile remain cloud-only.
- Desktop local inventory is keyed by Agent `hardware_id`; a merged row retains Backend `device_id` separately for account/Cloud authority, and `client_instance_id` is never a device identity. Startup may idempotently normalize only legacy Client-owned preferences/cache into `hardware_id`; it must not migrate credentials, Agent/Backend databases, or conversation history.
- Cold start preserves a persisted cloud device while cloud inventory is pending, and a successful authoritative inventory clears a stale missing cloud id before fallback. When no cloud inventory can arrive (cloud disabled, signed out, or cloud socket failed), a missing remembered device falls back visibly to an available device while the remembered id is kept until the user picks.
- Mobile/web cloud interruption, timeout, or `5xx/503` never implies logout. Keep the authenticated cached surface visible and stale/offline until authoritative inventory and active-history resynchronization succeeds.
- Sign-in completes authentication before cloud inventory exists, and the gateway can connect and drop once before the first fetch lands. That window is a pending inventory, never an authoritative empty: the device surfaces show a localized loading state (no "no devices" claim), the gateway status stays `connecting` instead of routing to onboarding, and the post-sign-in connect retries once before waiting for a resume-driven reconnect. Empty-state copy names devices, not agents.
- Local daemon health, lifecycle, update, socket, and voice endpoints derive from `AppConfig.localGatewayUrl`; never hardcode the production daemon port.
- Local Gateway access is desktop-only. Web and mobile remain remote-only and must never read a Local Gateway credential or attempt a local connection.
- Source-managed linked-worktree runs expose `worktree_runtime_badge` on desktop and compact/mobile layouts; Production builds with no worktree marker render no badge surface.
- Settings navigation controls used by interactive acceptance expose stable semantic widget keys across wide and compact layouts; `settings_back_to_conversations_btn` returns directly to `AppRoutes.home` instead of unwinding accumulated Settings history.
- A Gateway `auth_revoked` event is terminal for the authenticated Client family: clear local credentials and let the auth router show login immediately. Ordinary socket disconnects remain recoverable and never imply logout.

### Platform Boundaries
- `AppPlatform` (`client/lib/utils/app_platform.dart`) is the canonical platform discriminator. Shared startup (bootstrap, dependency registration, provider mounting) must never execute a native `dart:io` platform API; native implementations stay behind desktop-only registration and consumption boundaries.
- Client CLI is desktop-only: Web and mobile never register, construct, or read its host, settings cubit, ownership record, or Sanad Home.
- `client/lib/driver_main.dart` is the canonical test-driver entry point (`-t lib/driver_main.dart`). It enables Flutter Driver with operating system text-entry emulation preserved, installs the dictation capture seam before `main.dart` builds its providers, and registers all development VM service extensions in documented order: `auth_url`, `inspect_ui`, `enter_text`, `scroll`, `tap`, `reveal`, `hover`, then the dictation capture/probe/control group.
- Modular driver capabilities reside in `client/lib/driver/`: `driver_widget_filters.dart` (layout noise and key filtering, scope root resolution), `inspect_ui_extension.dart` (interactive UI tree snapshots and bounded type census), `interaction_extensions.dart` (gestures, tap target location, scrolling, text entry, element reveal, bounded long press, in-app synthetic hover), `ui_bounds.dart` (global bounds projection shared by snapshot, reveal, and obstruction reporting), `ui_inspection_state.dart` (widget enabled resolution), `ui_inspection_text.dart` (rendered text and bounded tooltip extraction), `ui_type_census.dart` (bounded type walks), and `dictation_capture_fixture.dart`/`dictation_probe.dart`/`dictation_driver_extensions.dart` (bounded PCM fixture capture, origin counters, and cubit phase/cancel; driver-only, never installed by production `main.dart`).

### Conversation Ownership
- `ConversationCacheStore` is the single client-side owner of conversation cache, device destinations, drafts, pagination resources, and workspace expansion.
- Conversation delivery, execution, attention, suspension, queue, steer, stop, replay, and recovery change only from matching authoritative outcomes.
- A send's acceptance wait ends only from its own request's outcome: a matching canonical acceptance clears the draft, while a typed `final_answer.error_code` refusal or a `blocked` runtime notice releases the wait and keeps the user's text, workspace, and route editable. The refusal is classified from the mapped canonical event, and a request id that names another request never releases this wait; an unattributed typed refusal may release only the one acceptance wait its own session can hold, and an unattributed `blocked` notice releases nothing. A refusal the daemon cannot persist stays visible as its own typed answer until an accepted user message for the same session supersedes it, and a selected session is presented by its id instead of being replaced by the identity placeholder while its device projection is unsettled.
- Session, draft, processing, and recovery state remain isolated by device/session identity; a selected session from another device cannot survive a device switch.
- Composer attachment picker, focused paste, and desktop drop share one routing matrix (`ComposerInputRouter`): attachments converge on `ConversationInputCubit`, and same-machine path tokens go to the composer text controller, whose file-reference link format has one owner (`FileReferenceLink`). Same-machine routing requires a desktop client and a matching agent hardware identity; web, mobile, and unknown identity are remote. Widgets never stage files or invoke socket transport directly. Attachment admission is enabled only by `supports_attachments=true`; optional versioned attachment metadata may refine limits, otherwise the canonical safe limits apply. Drafts stay device/session scoped, and send remains unavailable while any retained item is not `ready`. Plain-text pastes are captured by the macOS window runner at the key event (`com.eaststarai.sanad/pasteEvents` → `ExternalPasteManager`) because a dictation tool restores the pasteboard immediately after posting Cmd+V; the capture applies only to a plain Cmd+V (no Shift, Option, or Control) in the runner's own key window, the runner defers any pasteboard carrying a file URL or an image to this routing matrix, and non-macOS hosts insert the text held by the composer's own clipboard snapshot.
- One gate, `ComposerPermissionGate.shouldShow`, decides whether the composer offers the permission-mode picker: the Agent's tool-permission capability, no pending approval, and a bound workspace. A session whose targeting resolves to no path keeps the picker hidden rather than borrowing another workspace's policy, and no other widget re-derives that condition. The picker always renders the mode the Agent enforces — a session's own `allow_all_tools`/`permission_mode` metadata outranks the workspace policy — so a mode change is sent to the Agent (`workspace.set_permission_mode` plus `set_session_permission_mode` for the selected session) and never kept as a display-only downgrade. Its tooltip names the session's execution path, which is how an owner reads a session's working directory.
- `session_updated` applies only the keys the Client owns: `workspace_id`, `workspace_path`, `workspace_name`, `workspace_trust_state`, and the permission keys `metadata.execution_root`, `metadata.allow_all_tools`, `metadata.permission_mode`. Every other metadata key stays Client-owned, and a partial update never clears an owned key.
- Raw request id is transport identity. Display ids, timestamps, and optimistic UI rows cannot replace it.

### Dictation Ownership
- `client/lib/features/dictation/` owns dictation end to end: identity minting (`DictationIdentity`), the transport boundary, the resolver, the cubit/state, the composer mic, and the model sheet. `DictationTransportResolver` is the only place that chooses between the local socket channel and the hosted relay; nothing above the transport boundary may branch on connection scope, and a hosted selection that lacks `dictation_relay_v1`, an account device id, or an authenticated socket fails closed instead of degrading.
- Both channels must produce the same `{"event", ...fields}` vocabulary, because the session, insertion helper, and widgets are shared. A daemon-owned catalog row is identified by `label_code` and localized by the Client; the daemon never ships user-facing copy.
- Readiness is two facts: `supported` is the platform verdict, while `ready` plus `reason` is the current state. A supported-but-not-ready device keeps its reason so the setup action stays reachable, and the mic stays discoverable instead of hidden.

### Localization Ownership
- The client UI is multilingual (`en` + `ar` RTL). Translations live in `client/lib/l10n/app_en.arb` (English source of truth) and `app_ar.arb` (Arabic). Generated `app_localizations*.dart` files are build output and remain git-ignored; run `fvm flutter gen-l10n` after editing ARBs.
- Widget code holds no user-visible Arabic literals and no hard-coded English copy for localized surfaces; new user-facing strings must go through `AppLocalizations.of(context)` ("Show less", "Load more", section headers, settings pages, sidebar, relative time).
- The app locale is owned by `LocaleCubit` (`core/presentation/bloc/locale/locale_cubit.dart`) with SharedPreferences key `app_locale`. It silently falls back to `en` when the stored code is unsupported; no client page may crash on an unknown locale token.
- RTL mirroring is content-driven; layouts must use `Directionality`/start-and-end semantics, not absolute left-only assumptions when a surface must mirror.
- Widget keys are stable identifiers, never derived from a localized label: a key built from display text (`nav_tile_<label>`) changes identity when the locale changes and breaks every key-driven test and driver flow. Pass an explicit locale-independent id, keep the visible text in the label, and let `test/guards/locale_stable_widget_keys_guard_test.dart` guard the contract.

### Typography Ownership
- The font the user selects in Settings applies to every text surface. Widget code never names a font family: text inherits it from `Theme.of(context).textTheme` (or the ambient `DefaultTextStyle`), or resolves it through `AppTypography.text(context, ...)` in `client/lib/core/theme/app_typography.dart` when the style is built by hand — including `RichText` root spans, `ButtonStyle.textStyle`, `InputDecoration` styles, and dialog/overlay text.
- Monospace is one constant: `AppTypography.mono(...)` for code, diffs, terminals, paths, shell commands, and raw JSON. Machine-readable text is deliberately fixed and never follows the user's app font.
- Cairo is the default font for a profile with no saved preference and ships as a bundled Flutter asset family (`client/assets/fonts/Cairo-{Regular,Medium,SemiBold,Bold}.ttf`), so the default renders offline on every platform from the first frame. Inter and Roboto stay runtime-fetched Google Fonts; Cairo is never fetched at runtime.
- A stored `system` value is an explicit user choice and is never migrated to the default. Only a missing preference resolves to Cairo.
- No Apple-provided font may be bundled: text and iOS-style icons use Flutter-authored font assets (`CupertinoIcons` for the composer send arrow), because an embedded system typeface fails App Store validation as `ITMS-91182` (enforced from 2027-10-01), and `client/test/guards/no_apple_font_bundle_guard_test.dart` fails on any dependency, lock entry, asset name, or build manifest that carries one.
- `client/test/guards/no_hardcoded_font_guard_test.dart` fails on any `fontFamily:` literal or direct `GoogleFonts.<family>(` call outside `core/theme/app_themes.dart` and `core/theme/app_typography.dart`.

### Provider and Configuration Ownership
- Provider templates, instances, credentials status, model options, readiness, defaults, limits, and failover settings come from the agent provider runtime.
- Provider setup remains instance-first; the client must not hardcode providers, synthesize instances, or treat cached models as readiness.
- The setup picker (`ProviderPickerView`) renders `provider.templates.result` in arrival order; it must never sort, group, or reorder the agent catalog, because template declaration order is the intended setup order.
- The client manages the provider display-name catalog centrally in `ProviderUsageCubit`, isolated per device and decoupled from per-instance usage/support request generations. Authoritative snapshot boundaries are governed by internal `snapshotGeneration` in `ProviderSetupCubit`, ensuring successful provider mutations (`create`, `rename`, `remove`) in `ProviderSetupFlow` synchronize display names immediately without restarting the client; UI navigation, auth cancellation, intermediate forms, or load errors never advance generation and cannot clear cached catalogs, while pre-mutation in-flight responses cannot overwrite fresh state. Monotonic catalog generation authority persists across device clears to eliminate ABA stale-catalog races, and authoritative mutation snapshots neutralize pending in-flight loads.
- Mounted composer thinking controls synchronize model options, defaults, and capability revisions from authoritative `model.cache_updated` terminal events (`ProviderSetupClient.modelUpdates`) without route switch or client restart; freshness arbitration prefers authoritative snapshots differing in capability revision while preserving valid selections, repairing an invalid or removed selection only to the route's own known valid native default (otherwise to no selection at all), admitting that default as an ordinary option through the composer selection path, retaining prior validated authority across refresh failures, and strictly filtering cross-device and cross-provider events. A conversation transition that keeps the same route admits only that conversation's own default, dispatched under the composer's own active-conversation ownership, so no conversation is seeded from or written by its sibling and a valid explicit choice (including `Off`) is never overwritten. The declared native default is disclosed only by the menu-only provider-default hint below its own option inside the expanded menu, and the menu renders the declared choices strongest-first by reversing the declared order for display only.
- Provider instance surfaces render the daemon's typed connection projection, never a locally inferred status: a rejected credential names its sanitized category and endpoint, and a preset `fallback` model list is always labelled unverified.
- A `READY` card and a non-definitive failed check coexist without contradiction: the cause renders in a distinct warning style with the "Last check failed (<cause>); using the saved model list" sentence, never in the error style. Every category owns a localized sentence, so the daemon's English summary is never echoed through a fallback branch.
- Provider usage is a separate authority: `auth_required` from `provider.usage.result` never changes an instance card status; it is stated inside the usage section with a working `Reconnect` action that runs the same account re-authentication as the instance form (`ProviderSetupCubit.reconnectInstance` → `provider.auth.reconnect`), while a non-auth usage failure keeps `Retry` as a usage refresh. No second reconnect implementation may exist.
- A setup attempt that persisted a provisional instance always offers a non-destructive way back to the configured list; `Cancel -> Discard` may never be the only exit from a rejected-credential form.
- Setup verification is discovery-only (`probe: false`) and blocks only on a definitive failure (`failure.definitive`); a probe can never reject a valid key. The Test action consumes the same result and must distinguish a proven route (models plus probe round-trip), a partial success (key accepted, no model selected), and a non-blocking warning (the selected model did not answer) from a rejected credential.
- Never expose raw access,refresh,polling,device,provider,or recovery-owner credentials in logs or UI state. Socket and user-visible-error diagnostics must also omit command payloads,event content,custom names,and raw Client-instance identity;log bounded lifecycle/type/count metadata only.

## Development & Testing Requirements
Before concluding any task or development iteration in `sanad-agent/client`, choose verification based on the blast radius of the change:
1. **Run Static Analysis:** `fvm flutter analyze` for all code changes.
2. **Run Targeted Unit/Widget Tests:** Run the focused `fvm flutter test ...` command covering the changed behavior.
3. **Run the Full Fast Suite When Risk Warrants It:** Use `fvm flutter test` for broad UI/state/data-layer changes or when the touched code is shared across multiple features.
4. **Run E2E Only When Required By Scope:** `fvm flutter test e2e_test/` is required only for changes that affect real socket behavior, local daemon connection states, app/bootstrap runtime integration, worktree port/runtime isolation, or client/daemon contracts. E2E is intentionally expensive and must not be treated as mandatory for isolated UI, widget lifecycle, formatting, copy, or pure unit-level changes.
5. **Isolate Daemon-Backed E2E State:** Every spawned E2E daemon must receive a unique temporary `SANAD_STATE_HOME`, clean it after shutdown, and use the deterministic E2E provider. Tests must never inherit the live agent database or invoke the user's configured provider.
6. **Keep Fast Tests Deterministic:** Unit and widget tests await exact events or inject retry/timer policies; they must not wait through production request timeouts, reconnect backoff, polling intervals, or broad settling windows. Pure-Dart developer-tool tests belong to their owning package, not `client/test`.

When interface or runtime ownership changes affect the local daemon contract, prefer adding or updating a real daemon-backed test under `e2e_test/` instead of relying only on mocks.

## Definition Of Done
1. Follows all ownership, layer, and directory boundary rules.
2. Relevant tests are added or updated.
3. Analysis (`fvm flutter analyze`) passes without errors.
4. Targeted tests covering the changed behavior pass.
5. Full fast-suite and E2E results are provided only when the change scope requires them under the testing requirements above.
6. A new or grown non-generated `lib/` file stays inside the size ratchet: over 1000 lines it fails `test/guards/file_size_ratchet_guard_test.dart`, and an allowlisted file never exceeds its recorded count; split the file instead of raising the number.

## User-visible feedback
- Transient feedback goes through `ToastUtils` (`showInfo` / `showSuccess` / `showError`), which owns placement, duration, RTL and the close button.
- A `SnackBar` is acceptable only where a toast would be hidden (for example behind a full-screen modal barrier), and the call site must state that reason.
- Tests assert the message through `ToastUtils.debugOnShowError` / `debugOnShowInfo`, never by finding `SnackBar` widgets.

## Boundary Ownership
- Keep infrastructure-specific transport laws in the infrastructure domain.
- Keep feature-specific runtime laws in the nearest owning feature contract; do not duplicate them in this client-wide contract.
- `client/lib/features/client_cli/domain/models/client_cli_version.dart` owns the `sanad-client` CLI version literal. It is release-managed identity: release preparation advances it with the Client release version and CI rejects drift, so it is never edited by hand.
