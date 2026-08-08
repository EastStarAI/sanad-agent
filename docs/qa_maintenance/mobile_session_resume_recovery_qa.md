---
title: "Mobile Session and Resume Recovery QA"
description: "Regression matrix for typed refresh outcomes, foreground resume, stale cache continuity, and authoritative conversation resynchronization."
---

# Mobile Session and Resume Recovery QA

## Automated contract matrix

| Scenario | Expected result |
|---|---|
| Portal refresh succeeds with a rotated pair | Client persists and publishes the new pair, reconnects once, and remains authenticated. |
| Portal returns trusted `401` | Result is terminal; credentials and cloud user scope are cleared once and presentation becomes unauthenticated. |
| Portal timeout, DNS/connection failure, malformed response, `500`, or `503` | Result is transient; credentials and cached conversation state remain intact and no logout occurs. |
| Backend returns refresh `401` through Portal | Portal preserves `401` while replacing private detail with a bounded public message. |
| Backend is unreachable or returns non-`401` failure | Portal returns `503` without Backend body or credential detail. |
| Two socket auth failures arrive together | One refresh and one reconnect execute. |
| Pause/hidden then two rapid resume notifications | Resume notifications debounce into one reconnect without eagerly rotating a still-valid refresh token. |
| Initial process startup emits `resumed` | No resume recovery is started until the app has actually entered background/hidden state. |
| Live event arrives while history is in flight | Canonical history/live reconciliation renders the event once. |
| Two history requests for the same session complete newest-first | The older generation cannot overwrite the newer authoritative snapshot. |
| User switches sessions while old history is in flight | The previous session response cannot change the active session, messages, queue, or runtime notice. |
| Authenticated mobile/web client loses cloud access | Cached home remains reachable and the cloud status is `Offline` with retry; login is not shown. |

## Real-device smoke matrix

Run each row on both an iOS build and an Android build. Use a test account and
synthetic conversation content; evidence logs must not contain tokens, message
content, email, or absolute local paths.

1. Authenticate, background the app beyond the access-token lifetime, then
   foreground it with a valid refresh family. Confirm automatic recovery and a
   fresh open conversation.
2. Background the app, disable networking, foreground it, and confirm no logout,
   retained cached content, and an `Offline` indicator. Restore networking and
   confirm inventory/sidebar/history converge without manual login.
3. Revoke the current device refresh family while backgrounded. Foreground and
   confirm exactly one transition to login and no repeated refresh loop.
4. End or suspend a run from a second interface while the mobile app is in the
   background. Foreground and confirm processing/attention/runtime notice match
   authoritative history.
5. Deliver a live event during the history request and confirm one visible copy.
6. Revoke another device for the same account and confirm the current mobile
   device remains authenticated; disabling the user must invalidate both.

## Release evidence

- Focused Flutter unit/widget suites pass.
- Flutter analyzer passes without diagnostics.
- Portal refresh mapping tests pass.
- Existing Backend refresh rotation, replay, disabled user/device, and
  credential-store outage suites pass.
- iOS and Android smoke results record build identity, OS/device class, bounded
  timestamps, and pass/fail only.
- Any server cursor/watermark is out of scope unless these tests demonstrate a
  state that current inventory/session/history snapshots cannot recover.
