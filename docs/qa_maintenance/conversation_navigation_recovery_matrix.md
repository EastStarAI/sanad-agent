---
title: Conversation Navigation — QA Recovery Matrix
description: QA verification and recovery scenarios for conversation navigation, history, and deletion.
---

# Conversation Navigation — QA Recovery Matrix

## Scope

This matrix covers recovery scenarios for Plan 32e: navigation history, deletion safety, and cross-device consistency. Test each scenario on desktop and web (where applicable).

## Legend

| Icon | Meaning |
|------|---------|
| ✅ | Pass |
| ❌ | Fail |
| N/A | Not applicable |

---

## H1: Back/Forward Navigation

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| H1.1 | Open session A → session B → Back → see A | A is displayed; forward has B | ✅ |
| H1.2 | Open A → B → Back → Forward → see B | B is displayed | ✅ |
| H1.3 | Open A → B → Back → open C → forward is cleared | Forward stack is empty | ✅ |
| H1.4 | Re-select current session from sidebar | No history entry added; current unchanged | ✅ |
| H1.5 | Open A → New Conversation → Back → see A | A is displayed | ✅ |
| H1.6 | Open A → B → New Conversation → Back → see B | B is displayed | ✅ |
| H1.7 | Open A → B → C → Back (twice) → Forward (once) → see B | B displayed; forward has C | ✅ |

## H2: Browser Navigation (Web)

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| H2.1 | Browser back button after A → B | URL + content match B → A transition | ✅ |
| H2.2 | Browser forward button after A → B → back | URL + content match A → B | ✅ |
| H2.3 | Deep link `/conversations/device-1/session-1` on fresh load | Session 1 loads; no flash | ✅ |
| H2.4 | Deep link `/conversations/device-1/new` on fresh load | New Conversation surface loads | ✅ |

## H3: Across-Device Navigation

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| H3.1 | Navigate from device-1/session-A to device-2/session-B | Device switches; session B loads | ⬜ |
| H3.2 | Back after across-device navigation | Returns to device-1/session-A | ⬜ |
| H3.3 | Forward after H3.2 | Returns to device-2/session-B | ⬜ |

## D1: Non-Current Session Deletion

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| D1.1 | Delete a session not in back/current/forward | Current conversation unchanged | ⬜ |
| D1.2 | Delete session that IS in back stack | Removed from back stack; not visitable via Back | ⬜ |
| D1.3 | Delete session that IS in forward stack | Removed from forward stack; not visitable via Forward | ⬜ |

## D2: Current Session Deletion

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| D2.1 | Delete current; valid session exists in back stack | Falls back to last valid same-device session from back | ⬜ |
| D2.2 | Delete current; no back, valid session in forward | Falls back to last valid same-device session from forward | ⬜ |
| D2.3 | Delete current; no sessions in back/forward | Falls back to New Conversation for same device | ⬜ |
| D2.4 | Delete current; back has cross-device + same-device | Falls back to same-device session | ⬜ |
| D2.5 | After deletion, try to go Back | Does NOT return to deleted URL; returns to previous valid destination | ⬜ |
| D2.6 | Delete current session that is the only entry ever | Falls back to New Conversation | ⬜ |

## D3: External Deletion Events

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| D3.1 | `session_deleted` event for non-current session | Removed from cache/history/stacks; current unchanged | ⬜ |
| D3.2 | `session_deleted` event for current session | Same as D2.x fallback logic; no confirmation dialog | ⬜ |
| D3.3 | External delete while offline → reconnect | Session removed; fallback applied on reconnect | ⬜ |

## S1: Conversation History Search

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| S1.1 | Search a title or visible user/assistant phrase (including a thought) beyond loaded sidebar pages | One result per matching conversation from the selected Agent | ✅ Automated |
| S1.2 | Match exists only in system, reasoning-only, tool, private, superseded, or otherwise non-visible assistant content | No result is produced from that content | ✅ Automated |
| S1.3 | Search Arabic text and English text with ASCII case/whitespace variation | Deterministic results follow the documented normalization | ✅ Automated |
| S1.4 | Type two queries quickly, clear during a request, or change query during load-more | Stale generations never replace or append results | ✅ Automated |
| S1.5 | Search returns empty or fails | Explicit empty or retryable error state; no sidebar cache is presented as complete results | ✅ Automated |
| S1.6 | Select a content hit outside the loaded history page | Atomic swap loads the Agent-issued anchor and opens the matching event | ✅ Automated |
| S1.7 | Use wide and compact layouts | Wide dialog and compact bottom sheet expose equivalent controls and results | ✅ Widget / manual compact smoke |
| S1.8 | Confirm IME composition or use arrows, Enter, clear, and Escape | Composition does not select early; keyboard controls remain usable | ✅ Automated |
| S1.9 | Reuse a cursor with another query or send invalid bounds | Agent returns a correlated typed error and no misleading page | ✅ Automated |
| S1.10 | Select a result absent from partial sidebar pages, then select it again after scrolling the open session away from its anchor | The route remains on the result session with its real title/workspace metadata; no sidebar **Load more** is required; the second selection remounts the anchored timeline even when the event is already loaded | ✅ Automated + live driver |

## V1: Timeline Viewport Restoration

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| V1.1 | Open an idle session with a valid saved viewport event | Saved event starts near the visible top without eagerly building all older history | ✅ Automated |
| V1.2 | Open a long session with authoritative active work and a stale saved viewport event | Saved event is ignored; latest event ends at the visible bottom immediately above the composer while old history remains lazy | ✅ Automated |
| V1.3 | Existing thinking or final-answer content streams while follow is active | Fully visible growth preserves pixels; growth crossing the composer uses only the hidden-distance minimal reveal without Scroll animation | ✅ Automated |
| V1.4 | User manually scrolls away from the tail | Reading position is recorded and live growth does not overwrite it programmatically | ✅ Automated |
| V1.5 | Active session first frame uses an estimated composer height | Timeline stays unpainted until the first real measurement, then appears once at its final position with no transient motion | ✅ Automated |
| V1.6 | An empty timeline accepts its first user message | User message becomes the visible top anchor without animation and short assistant output grows below it | ✅ Automated |
| V1.7 | A non-empty timeline accepts a fully visible user message | Event appends in canonical order without changing pixels or rebuilding the anchor | ✅ Automated |
| V1.8 | A new user row is partly hidden behind the composer | Timeline moves only by the obscured distance; the row bottom clears the visible boundary without animation | ✅ Automated |
| V1.9 | A new user row is wholly below the viewport with later events after it | Lazy layout is preserved; the complete user row is minimally revealed without jumping to the conversation tail | ✅ Automated |
| V1.10 | Minimal reveal completes while follow eligibility is disabled | Later reasoning, tool, final-answer, informational, and runtime events preserve the reveal offset | ✅ Automated |
| V1.11 | An eligible new agent event has not reached the composer | Viewport remains fixed; only a structurally new event crossing the boundary may activate direct tail follow | ✅ Automated |
| V1.12 | User manually moves away while active work streams | Eligibility and active follow clear immediately; multiple later event kinds preserve the manual offset | ✅ Automated |
| V1.13 | User manually returns to the bottom | Eligibility is restored; later new events and followed stream growth may use boundary-gated minimal reveal | ✅ Automated |
| V1.14 | Opening, user reveal, same-id growth, or composer correction settles | Placement is direct and leaves no ScrollController animation active | ✅ Automated |
| V1.15 | Open authoritative active work whose complete content is shorter than the viewport | Timeline is top-aligned before paint; no empty upper page or bottom-attached content appears | ✅ Automated |
| V1.16 | A new user message arrives through widget-state projection in a non-empty active session | It receives minimal reveal and never rebuilds the opening anchor or moves to the top | ✅ Automated |
| V1.17 | A structurally new agent event appears | A 220ms paint-only fade/slide runs once; completion removes transition composition, hover geometry stays fixed, and same-id updates do not animate | ✅ Automated |
| V1.18 | A structurally new agent event arrives while active tail follow is already set | Scroll remains in progress before 280ms, uses ease-out motion toward the new extent, then settles at the exact tail | ✅ Automated |

## R1: Late / Stale Response Handling

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| R1.1 | Navigate A → B quickly; history response for A arrives after B loaded | Discarded (stale generation) | ✅ |
| R1.2 | Delete current session C; late history response for C arrives | Silently discarded | ⬜ |
| R1.3 | Navigate A → B → A (quickly); first A response arrives after second A navigation | First A response discarded if generation superseded | ⬜ |
| R1.4 | Navigate to New Conversation; late response for previous session | Discarded | ✅ |
| R1.5 | Switch from a session with provider/model/thinking context to a complete session summary with no route context | Previous route and thinking values are explicitly cleared; only an identity-only `Loading...` placeholder may preserve the persisted route until hydration | ✅ Automated |

## R2: Loading States

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| R2.1 | Fast session load (< threshold) | Atomic swap; no loading overlay | ✅ |
| R2.2 | Slow session load (> threshold) | Delayed loading overlay above previous content | ✅ |
| R2.3 | Session load failure | Previous conversation stays; retry available | ✅ |
| R2.4 | New Conversation load | No loading; immediate compose surface | ✅ |

## RS1: Restart Recovery

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| RS1.1 | Restart with a valid saved session destination | Same session loads | ✅ Automated |
| RS1.2 | Restart after selecting New Conversation without a workspace | New Conversation loads with no workspace selected | ✅ Automated |
| RS1.3 | Restart after selecting New Conversation with a workspace | New Conversation loads with that workspace selected | ✅ Automated |
| RS1.4 | Restart with saved session deleted while offline | Falls back to New Conversation | ⬜ |
| RS1.5 | Restart with no saved destination | Default device's New Conversation loads | ✅ Automated |
| RS1.6 | Deep link on restart: `/conversations/device-1/session-1` | Session 1 loads after bootstrap | ⬜ |
| RS1.7 | Deep link on restart: `/conversations/device-1/new` | New Conversation after bootstrap | ⬜ |

---

## Test Execution Guidelines

1. Execute matrix per platform (desktop, web) where applicable.
2. Start each test from a clean cache state.
3. Record status (✅/❌) and any deviations.
4. Report failures to the development agent with reproduction steps.
