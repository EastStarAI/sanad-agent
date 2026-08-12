# Conversations Presentation Contract

## Scope
This contract applies to `client/lib/features/conversations/presentation/`.

## Cubit and Widget Ownership
- Cubits translate user intent into repository operations and project domain state; they must not parse socket events or own duplicate stores.
- Keep large conversation entry widgets as orchestration boundaries and extract stateless/presentational slices.
- Extract user message rendering into `UserMessageTile`; user messages exceeding 5 lines default to a 5-line collapsed height with a bubble-wide tap toggle ("Read more" / "See less") and smooth height animation.
- The parent composer owns long-lived text controllers, focus nodes, and inline suspension coordination.

## New Conversation and Composer
- `ConversationInputPanel` is the single composer for New Conversation and existing sessions; do not fork an editor or draft lifecycle into another view.
- Bind drafts by device plus session, or standalone device identity for New Conversation.
- Flush debounced edits before send, session/device transition, and disposal; unrelated cache snapshots must not clear editor text.
- Draft workspace, provider, model, thinking, and text restore together per device. Permission remains workspace-policy-owned and must not be mutated by restore.
- Existing-session selection must replace or explicitly clear all context fields before presentation swaps. An identity-only restored-session placeholder is not authoritative context and must preserve the persisted provider/model route until a complete route or authoritative route revision arrives.
- `thinkingMode` is the Dart/domain name and `thinking_mode` is the wire/cache key; do not add aliases.
- For a new device with no saved thinking preference, initialize and persist `balanced`; preserve any non-empty returning-user value.
- A partial provider/model preference is not a valid route. Authoritative readiness may complete or replace a partial pair, while a complete saved pair remains user intent.
- Do not eagerly hydrate history for a session created locally for its first outgoing turn.
- Block normal message dispatch before session creation when either the provider instance or model selection is absent.
- Slash queries run only on explicit composer intent and use the daemon query surface, never local skill discovery or mount-time prefetch.
- Route every workspace-path picker entry through the shared picker helper. Use
  the native folder picker only for a confirmed same-desktop local device;
  remote selection shows the security notice and sends no filesystem command.

## Delivery Controls
- Enter/send emits typed automatic intent; Command+Enter and Control+Enter emit typed queue intent.
- Keep queue, steer, delete, stop, retry, and replay controls pending until authoritative outcomes arrive.
- While execution is stopping, keep Stop visible and disabled with its progress presentation.
- Keep Stop available for runtime notices advertising stop even when processing is false.
- Recovery Stop must not clear banners optimistically.
- Recovery Retry and Change Provider send provider instance plus model atomically whenever both are known.
- Latest-turn inline edit state is transient and session-bound, cancels on session/device navigation, and must not stop work before confirmation of unsafe or unknown replay.

## Suspension Presentation
- Render permissions, clarifying questions, and runtime notices inline in the active conversation; do not use app-global approval dialogs.
- Block normal sending only in the session with the pending suspension.
- Preserve pending UI until authoritative resolution.
- Permission cards use action-specific titles and readable labeled fields for known command, file, search, and MCP actions; unknown tools fall back to action-neutral language. Render only daemon-provided display input and never reconstruct redacted arguments. Visually separate the darker request content from the prompt and choices.
- A running tool row whose matching suspension awaits permission shows the permission shield instead of progress; `system_ask_user` shows the question icon while awaiting an answer. Unblocked running tools retain progress.
- Keep background suspension and recovery state out of the active composer while surfacing its session-row attention state.

## Atomic Session Presentation
- Track requested session separately from presented active session.
- Preserve the current timeline until requested history loads successfully; gate repository streams while a request is pending or failed.
- Advance a request generation for each navigation and ignore superseded responses.
- Load history through the repository's atomic history operation; do not activate separately before swap.
- Fresh locally created sessions may swap immediately without history round-trip.
- Show delayed loading only after the centralized threshold and cancel its timer on success, failure, supersession, or disposal.
- Failed loads retain the prior presentation, keep stream gating, expose retry, and retry with a new generation.
- During a transition, timeline ownership follows the presented active session while draft ownership follows the requested session immediately.
- Render App Bar session metadata only when its session id equals the presented active session id.
- Choose a session's opening timeline anchor once: authoritative active work opens at the latest event; otherwise restore the persisted manual-scroll event when valid, then fall back to the latest user message.
- Record viewport anchors only after user-driven scrolling settles; programmatic positioning, follow-tail, and layout growth must not overwrite the saved reading position.
- Keep follow eligibility separate from active tail follow: only active-tail opening or a manual return to the bottom grants eligibility, and active follow begins only when eligible content reaches the composer boundary.
- Never bottom-align a short Timeline with an empty upper viewport. Resolve active opening before paint: top-align complete short content, otherwise keep the lazy tail opening.
- Manual movement away clears both follow states immediately. Agent events must preserve the offset while ineligible.
- Mutation or growth of an existing thinking, reasoning, or final-answer row preserves the exact offset while follow is ineligible; while actively following, it may use only the minimum direct reveal needed when its bottom crosses behind the composer.
- Give structurally new agent events a paint-only entrance transition; never animate history opening, user insertion, or repeated updates to an existing event id. Remove opacity/transform composition after entrance completion and do not add per-event repaint boundaries.
- ScrollController animation is allowed only for a structurally new agent event received while active tail follow was already set; use the centralized 280ms ease-out duration. Opening, user minimal reveal, followed same-id growth, composer correction, and eligible-but-inactive boundary activation remain direct.
- In a non-empty timeline, reveal a new user row only when needed and only by the minimum direct, animation-free offset that clears the composer; this must not mutate follow eligibility or rebuild the opening anchor.

## Device Switch and Sidebar
- Missing workspaces remain visible with historical sessions; disable new workspace conversation intent and route hover-only workspace settings actions with explicit device and workspace ids.
- `SessionSidebarCubit` is a pure projection of `ConversationCacheRepository.snapshotStream`; it owns no cache maps, cursors, or drafts.
- Device selection comes from `DeviceCubit`; session/workspace data comes from the conversation cache repository.
- Project cached workspace mutations into the composer selector immediately. Opening a popup must never be required to refresh state, and a newly created workspace must be present on the selector's first opening.
- Invalidate a selected session from another device before restoring the new active device's last destination.
- Do not request a collapsed workspace's first page during refresh.
- Preserve canonical mutations received during in-flight pagination and do not remove newer workspaces with older responses.
- Keep responsive sidebar constants centralized in `sidebar_composition.dart`.
- Keep the legacy `SessionSidebar` as a forwarding compatibility shell only; do not add state or behavior to it.
- Unscoped changes must not rebuild the workspace section; processing, suspension, and selection changes should rebuild only affected rows.
- Cached content remains visible through offline, refresh, and stale-error states.
- Preserve labeled, keyboard-focusable controls and 44px-class primary drawer/mobile targets.
- Presentation must not synthesize missing cache capabilities; extend the domain/data owner instead.

## Navigation and Deletion
- `NavigationHistoryController` solely owns back, current, and forward destinations; widgets must not keep parallel history.
- Synchronize session selection, New Conversation, browser history, and GoRouter changes through the shared controller without update loops.
- Do not optimistically clear the current selected session before deletion confirmation.
- Non-current deletion removes cache/draft/history identity without changing current presentation.
- Current deletion applies confirmed cache removal, prunes history, replaces the current route, and chooses fallback deterministically:
  1. newest valid same-device back destination;
  2. newest valid same-device forward destination;
  3. New Conversation for the same device.
- External deletion events follow the same fallback invariants.
- Ignore late history for deleted or superseded sessions.
- Route replacement after current deletion must prevent the deleted URL from re-entering history.

## Presentation Fidelity
- Running and completed assistant Markdown enter through one application-owned renderer boundary; progressive rendering must not own timeline scrolling, add artificial typing, or be silently bypassed in widget tests.
- Provider chips render daemon-owned display names and model names, never raw provider UUIDs. Session display metadata is valid only when its provider identity matches the active or staged provider route.
- Context-usage UI shows only the latest active-session snapshot, includes cached input only when available, and never displays cache-write usage.
- Composer controls remain horizontally bounded on narrow layouts and expose Material semantics, labels, and keyboard focus.
