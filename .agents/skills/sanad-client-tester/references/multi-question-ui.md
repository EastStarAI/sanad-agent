# Multi-question UI and parsing

Load this reference when developing or testing multi-step `system.ask_user` suspension checkpoints.

## Parsing boundary

The daemon WebSocket event may provide `questions`, or fallback `question`, at the event root rather than only inside `tool_input`. `AgentSuspendedRequest.fromJson` must map root-level values into `toolInput`; otherwise the UI derives an empty question list and silently hides the interaction card.

## Navigation contract

- `_AgentInputPanelState` presents exactly one question at a time.
- Each question exposes exactly three predefined options plus the custom-text choice.
- Dynamic keys identify question and option indices, for example `ask_user_option_0_1`.
- The custom field uses `ask_user_custom_input`.
- `ask_user_back_btn` decrements the current question index without discarding previously entered selections or custom text.
- Tests cover forward navigation, back navigation, state preservation, final submission shape, and root-level payload parsing.

## Live verification

Changes to `AgentSuspendedRequest`, BLoC state, persistence schemas, or equivalent model layers require `sanad-dev restart client`; hot reload cannot reliably replace those runtime representations. After restart, re-establish runtime ownership, then use keyed Driver actions from `interactive-ui-testing.md`.
