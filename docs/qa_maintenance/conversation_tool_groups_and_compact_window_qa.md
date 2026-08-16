---
title: "Conversation Tool Groups and Compact Window QA"
description: "Regression matrix for completed-tool grouping, nested and timeline follow, active-history completion, ask-user presentation, and desktop compact sizing."
---

# Conversation Tool Groups and Compact Window QA

## Automated coverage

| Surface | Scenario | Expected evidence |
| --- | --- | --- |
| Projection | One terminal tool, then a second contiguous terminal tool | One stays standalone; two become one stable group |
| Boundaries | Ask-user, user/assistant, plan, or informational event | No group crosses the event |
| Running batch | Two or more contiguous tools include running calls | Every call enters one group; no running tool remains standalone |
| Activity visibility | Stable reasoning is visible, then the first and second tools of a burst arrive | The prior confirmed row stays visible through the temporary standalone tool; no activity for that tool flashes; the grouped run replaces it only after debounce |
| Activity burst debounce | Six parallel tools arrive inside one second | The last confirmed activity remains visible; intermediate candidates never render; only the sixth/latest stable real detail replaces it directly after one quiet second, with no entrance/text animation |
| Activity boundary | A tool group is followed by ask-user, its answer, then new reasoning | The old group never gains later content; the new activity appears at the timeline tail after the question/answer |
| Activity transparency | A grouped shell/file/web tool is running | The activity row exposes the real command, path/action, query, or URL rather than the raw tool name |
| Activity eligibility | Attention becomes waiting, blocked/fatal, stopping, idle/interrupted, erroneous, or requires user input | The activity and pending timer disappear immediately; only authoritative running/resuming can render it |
| Activity copy | Provider/tool work is active without a reasoning preview | The generic row says `Working…`; explicit reasoning alone retains `Thinking: <preview>` |
| Activity elapsed baseline | Active work has a daemon snapshot baseline below one hour, then crosses one hour | The trailing label uses tabular digits so same-length updates remain stationary, shows seconds below one hour and hours/minutes thereafter, and never restarts from widget mount time |
| Activity reopen/reconnect | Leave an active conversation, return later, then reconnect and hydrate the same execution revision | The timer resumes from the cached baseline plus local elapsed time; the hydrated newer observation refreshes it without an execution-revision conflict |
| Runtime duration recovery | A turn waits, blocks for user input, resumes, or is recovered after daemon restart | Final `runtime_ms` and live elapsed time retain the original accepted-work start instead of measuring only the last execution segment |
| Activity lifecycle | Ordinary thought/final text, stop, or idle historical reopen follows active work | The transient activity row disappears and no blank placeholder remains |
| Group title | Mixed MCP, non-file, read, write, and edit calls | The complete title uses normal font weight; MCP operations aggregate by server as tool counts; no leading icon or `Tool uses:`; skill loads lead before other non-file operations, file impact trails, green/red line counts are compact and last, and the chevron is title gray |
| Metric animation | Any existing operation/file/line count increases | The changed number animates over 750ms without replaying on expansion or virtualization |
| Expansion | Expand group, one child, and a standalone tool; virtualize and return | The aggregate title appears only in the outer header; each expansion state survives independently and other children stay collapsed |
| Lazy body/cache | Collapse group, scroll away/back, then update totals | Collapsed body is absent; cached totals do not animate on scroll and animate only on change |
| Aggregation | Repeated reads/edits on the same normalized path | Unique file counts remain one; tool-kind counts retain every call |
| Diff metrics | Write/edit input and patch output | Added/removed totals match changed lines and animate on update |
| Ask user | Running and completed states | Running timeline row is absent; completed Q/A has no generic header |
| History race | Terminal live tool result arrives during stale running history request | Terminal status/output survives and merges with persisted input |
| Group scroll | Open tall group, scroll away, append tools, return to bottom | Offset is preserved while opted out; follow resumes at bottom |
| Timeline scroll | Send user row, then stream growth and delayed Activity layout; manually scroll away and return | Send restores eligibility; thinking, groups, and post-debounce Activity follow the outer timeline until manual outer-scroll opt-out |
| Scroll isolation | Scroll inside an expanded tool/group while conversation follow is active | Inner controllers and follow state remain independent and never opt the outer conversation timeline in or out |
| Isolation | Scroll the group and the timeline separately | Each controller and follow state changes independently |
| Desktop header | Native desktop vs mobile/web | Compact control appears only on desktop and matches pin geometry; the macOS narrow drawer begins below native traffic lights |
| Window bounds | Compact, restore, then manual minimum resize | Compact uses `500 × 874`, top-left origin is preserved, previous bounds restore, and resizing stops at `500 × 600` |
| Window state | Enlarge manually from compact mode | Compact state clears and both wide/narrow toggle icons update |
| Composer focus | Open New Conversation, then click blank composer padding | Input starts focused and blank clicks restore focus without stealing button actions |
| Composer file drop | Drop one or more files with a collapsed caret, an active selection, and an invalid selection | Paths insert at the caret, replace the selected range, preserve separator spacing, and fall back to the end only for invalid selection |
| Native runners | macOS, Windows, Linux source contract | Every runner enforces the same logical minimum |

## Focused commands

Run the client analyzer and these focused suites through FVM:

- `agent/test/evolution/authoritative_session_state_repository_test.dart`
- `agent/test/engine/agent_runner_test.dart`
- `client/test/unit/presentation/conversation_timeline_projection_test.dart`
- `client/test/unit/presentation/composer_text_editing_test.dart`
- `client/test/unit/stores/session_execution_registry_test.dart`
- `client/test/widget/conversation_activity_tile_test.dart`
- `client/test/widget/tool_group_tile_test.dart`
- `client/test/widget/brain_activity_view_scroll_test.dart`
- `client/test/unit/services/device_conversation_commands_test.dart`
- `client/test/widget/device_workspace_sidebar_structure_test.dart`
- `client/test/tool/desktop_window_contract_test.dart`

## Live review

1. Open an active conversation with at least two completed contiguous tools.
2. Confirm the collapsed title uses the existing tool title color and component styling.
3. Expand the group, verify the 500px cap, and exercise independent nested follow.
4. Confirm an active ask-user question appears only in the composer and its completed answer has no generic header.
5. Press the desktop phone-size button, verify `500 × 874` while the top-left origin stays fixed, then use the narrow-header button to restore the prior bounds.
6. On macOS, confirm the narrow header's Menu and restore actions begin after the native traffic lights; open New Conversation and confirm both actions remain available there.
7. Attempt to resize below the minimum on the current desktop platform.
8. Send a new message while not at the full tail; verify only the user row is revealed, then verify subsequent streamed growth follows until manual upward scrolling.
