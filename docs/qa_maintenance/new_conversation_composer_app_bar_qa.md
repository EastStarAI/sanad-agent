---
title: "New Conversation, Composer, and App Bar QA"
description: "Focused Plan 32d scenarios for unified composition, device-scoped drafts, responsive actions, and atomic session presentation."
---

# New Conversation, Composer, and App Bar QA

## First-run defaults

- With no saved thinking preference, New Conversation displays and sends
  `balanced`; the first capability-list item must not implicitly become the
  default.
- A non-empty saved thinking preference is restored unchanged.
- A provider-only or model-only restored preference is incomplete. A successful
  authoritative readiness pair fills both selector values.
- A complete saved provider/model pair remains unchanged unless an explicit
  authoritative replacement flow owns the update.

## Scope

This matrix validates the Plan 32d client surface without changing daemon authority. It covers the shared composer used before and after session creation, draft ownership transitions, and the session metadata shown above conversation content.

## New Conversation

| Scenario | Expected result |
|---|---|
| Open Home without an active session | `Sanad Agent`, the help text, context selectors, and the unified composer appear; no Conversation App Bar appears. |
| Select or clear an optional Workspace | The selection updates the current device draft without creating a session. |
| Attempt a first send while Workspace is required but absent | Dispatch is blocked and a clear validation message is shown. |
| Complete first-run provider setup with no prior composer route | The provider setup overlay closes automatically; the authoritative active provider instance and model appear in the composer immediately and are retained for that device. |
| Complete first-provider setup while retired client preferences reference a deleted provider UUID | The authoritative new provider UUID and model replace the stale pair atomically; the composer shows the provider display name plus model and the first send targets the new instance. |
| Complete provider setup while a composer route already exists | The existing provider/model selection remains unchanged. |
| Skip provider setup and attempt to send without a provider or model | Dispatch and eager session creation are both blocked, the draft remains available, and `Select a provider and model before sending a message.` is shown. |
| Send the first message with or without a Workspace | The session is created eagerly before dispatch (unified session-creation path), the view navigates to the new session immediately, and the first message is sent on that session id. There is no deferred daemon-side draft creation. |
| Press the top-level New Session action | The selected device's last opened session supplies Workspace, provider, model, and thinking context; no other device's context is used. |
| Let cache and draft updates settle after pressing New Session | The route remains `/conversations/:deviceId/new`, the previous session stays unselected, and its history is not requested again. |
| Reconcile the same New Conversation device and Workspace route | Route reconciliation is idempotent: new-session initialization and Workspace-policy loading are not repeated. |
| Open an existing session while New Conversation contains draft text | The target session composer binds immediately and never renders the New Conversation text during history loading; the New Conversation draft remains preserved. |
| Select a Workspace from its sidebar plus action | New Conversation opens with that Workspace overriding any previous draft Workspace, while provider/model/thinking restore from the same device's last session; no create-session request occurs before send. |
| Restore or switch a New Conversation Workspace | Permission is loaded from the target Workspace policy. Draft restoration never sends `workspace.set_permission_mode` and never inherits another Workspace's permission. |

## Draft Ownership and Acceptance

| Scenario | Expected result |
|---|---|
| Type and send before the debounce interval expires | The complete text is persisted before dispatch and survives a failed send. |
| Receive an unrelated sidebar/cache snapshot while typing | The in-progress editor text remains unchanged. |
| Switch devices while both devices are on New Conversation | The previous device draft is flushed under its own id and the target device draft replaces the editor text. |
| Switch sessions or dispose the composer during the debounce window | The last edit is flushed under the identity being left. |
| Receive canonical acceptance with the matching request id | Only the matching draft and editor text are cleared. |
| Edit again after dispatch, then receive acceptance for the older request | The newer text remains because its pending marker no longer matches the old request. |
| Restore a New Conversation draft | Text plus Workspace, provider, model, and thinking return for the same device; permission is re-read from Workspace policy rather than the draft. |

## Conversation App Bar

| Scenario | Expected result |
|---|---|
| Open an existing session with empty history | The App Bar still renders the session title while the empty content is ready. |
| Open a Workspace session on desktop/tablet | Workspace and session titles render in hierarchy and truncate without overflow. |
| Open an unscoped session on mobile | Menu and session title render with no empty Workspace subtitle. |
| Selected-session metadata temporarily differs from active content | The App Bar waits for metadata matching the active session id; it never shows the other session title. |
| Update title or Workspace metadata for the same session id | The App Bar refreshes without requiring a session-id change. |

## Composer Responsiveness and Accessibility

| Scenario | Expected result |
|---|---|
| Render permission/model/thinking controls at a narrow mobile width | Controls remain bounded and horizontally reachable without a RenderFlex overflow. |
| Expand the editor beyond eight visible lines | The editor stops growing and scrolls internally. |
| Navigate send, stop, and voice actions by keyboard or screen reader | Each action is focusable, labeled, and has a 48-by-48 logical target. |
| Use a device without voice-call capability | The voice action remains hidden; the disabled capability is not presented as available. |
| Send with hardware Enter or the send button on desktop while execution is `running` or `resuming` | Both dispatch `auto`; the daemon may classify the message as pending steer and the UI shows the running-only `Press Enter to steer` tooltip. |
| Press software-keyboard Enter on Android or iOS | A newline is inserted and no message is dispatched; the visible send button remains the submission action. |
| Press Shift+Enter on desktop | A newline is inserted and no message is dispatched. |
| Press Control+Enter or Command+Enter | The composer dispatches explicit `queue` intent without inserting an unintended newline. |
| Use Enter while the session is idle, waiting, blocked, queued, or stopping | The client still sends intent rather than deciding steer locally; only a live steerable run may receive a pending steer. |

## Conversation Opening and Reading Position

| Scenario | Expected result |
|---|---|
| Open an idle session without a saved viewport anchor | The latest user message is placed at the opening anchor. |
| Manually scroll an idle session, leave it, and reopen it | The top visible event recorded when scrolling settled is restored. |
| Open a session whose saved event is absent from loaded history | Opening falls back to the latest user message without an error. |
| Open a running, queued, waiting, blocked, resuming, or stopping session with an older saved anchor | Authoritative active work wins and the latest event is shown. |
| Let programmatic follow-tail scrolling or layout growth occur | No manual reading anchor is recorded. |
| Send and receive canonical acceptance for a new user turn | The older reading anchor is removed. |
| Delete the session or device | Its viewport anchor is removed with the other session-owned cache state. |

## Automated Coverage

- `conversation_input_panel_rebuild_test.dart` covers unrelated snapshot protection, immediate-send flushing, canonical cleanup, device switching, disposal flushing, context metadata persistence, and missing provider/model presentation validation.
- `conversation_input_cubit_test.dart` covers authoritative empty-route initialization, preservation of an existing route, route preference persistence, and defense-in-depth dispatch rejection.
- `provider_setup_flow_test.dart` covers propagation of the authoritative readiness snapshot through the ready callback.
- `conversation_input_composer_toggle_test.dart` covers responsive bottom controls, auto/queue keyboard intents, running-only tooltip behavior, runtime stop behavior, and accessible action targets.
- `conversation_app_bar_test.dart` covers empty active sessions, long desktop labels, and the unscoped mobile layout.
- `brain_activity_view_scroll_test.dart` protects last-user fallback, persisted idle-session anchors, active-work latest-event precedence, manual-scroll recording, shared composition, and long-history behavior.
- `conversation_cache_store_test.dart` and `conversation_cache_codec_test.dart` protect anchor scoping, invalidation, cleanup, and restart persistence.
- `session_selection_sync_test.dart` covers the unified first-send session-creation path: eager `createSession` with and without a Workspace, immediate `selectedSession`/`activeSessionId` synchronization, and single-session continuity across follow-up sends.
