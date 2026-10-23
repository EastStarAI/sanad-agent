"""The code-owned action table for the Sanad Client decision layer.

One table owns three facts that must never be delegated to a model:

1. **scope** - which controls are valid decision targets in a given screen mode;
2. **mechanics** - whether a candidate is a tap or a text entry;
3. **consequences** - which preconditions the snapshot must satisfy, and which
   actions are irreversible.

Because scope lives here, a key that is absent from this table is invisible to
the decision layer. That is deliberate: an unclassified control fails closed
(the guard refuses ``unclassified_target``) instead of being offered to a model
as if it were safe. Adding a control therefore means adding a rule *and* a
fixture, never loosening the guard.

B10 measured why this is not optional: with a screen-agnostic table the 32-item
cap removed the correct target on the device page, and ``submit`` stayed
available with an empty answer field, which the model then selected at 0.98
confidence. Scope fixes the first defect; ``field_filled`` fixes the second.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Dict, Optional, Pattern, Tuple

from .modes import (
    ASK_USER_CARD,
    ASK_USER_CUSTOM_INPUT,
    COMPOSER_POPUP,
    CONVERSATION_IDLE,
    CONVERSATION_RUNNING,
    CONVERSATION_SEARCH,
    MODEL_PICKER,
    PERMISSION_CARD,
    PERMISSION_DENY_COMMENT,
    SETTINGS,
)

TAP = "tap"
TYPE = "type"

TIER_CHROME = "chrome"
TIER_DECISION = "decision"

CONVERSATION_MODES = (CONVERSATION_IDLE, CONVERSATION_RUNNING)

# Precondition verbs understood by ``guard.py``.
FIELD_FILLED = "field_filled"
FIELD_PRESENT = "field_present"
DETAIL_IS = "detail"
MODE_IS = "mode"


@dataclass(frozen=True)
class ActionRule:
    """One declared control class and its code-owned consequences."""

    name: str
    pattern: Pattern[str]
    modes: Tuple[str, ...]
    action: str
    family: str
    tier: str = TIER_DECISION
    preconditions: Tuple[str, ...] = ()
    irreversible: bool = False
    reason: str = ""


def _rule(
    name: str,
    pattern: str,
    modes: Tuple[str, ...],
    action: str,
    family: str,
    tier: str = TIER_DECISION,
    preconditions: Tuple[str, ...] = (),
    irreversible: bool = False,
    reason: str = "",
) -> ActionRule:
    return ActionRule(
        name=name,
        pattern=re.compile(pattern),
        modes=modes,
        action=action,
        family=family,
        tier=tier,
        preconditions=preconditions,
        irreversible=irreversible,
        reason=reason,
    )


# Order is significant: the first matching rule wins, so specific controls are
# declared before the family wildcard that would otherwise swallow them.
ACTION_RULES: Tuple[ActionRule, ...] = (
    # --- conversation composer ------------------------------------------------
    _rule("send_message", r"^send_message_btn$", (CONVERSATION_IDLE,), TAP,
          "composer", preconditions=(f"{FIELD_FILLED}:chat_input",),
          irreversible=True,
          reason="sends a message to an external model provider"),
    _rule("stop_message", r"^stop_message_btn$", (CONVERSATION_RUNNING,), TAP, "composer"),
    _rule("chat_input", r"^chat_input$", CONVERSATION_MODES, TYPE, "composer"),
    _rule("composer_attachment", r"^composer_add_attachment$", CONVERSATION_MODES, TAP,
          "composer"),
    _rule("model_selector", r"^model_selector_btn$", CONVERSATION_MODES, TAP, "composer"),
    _rule("permission_mode_selector", r"^permission_mode_selector_button$",
          CONVERSATION_MODES, TAP, "composer"),
    _rule("thinking_mode_selector", r"^route_thinking_mode_selector_button$",
          CONVERSATION_MODES, TAP, "composer"),
    _rule("workspace_selector", r"^workspace_selector_btn$", (CONVERSATION_IDLE,), TAP,
          "composer"),
    _rule("edit_message", r"^edit_message_button$", CONVERSATION_MODES, TAP, "timeline"),
    _rule("retry_message", r"^retry_message_button$", CONVERSATION_MODES, TAP, "timeline"),
    _rule("fork_conversation", r"^fork_conversation_button$", CONVERSATION_MODES, TAP,
          "timeline"),

    # --- sidebar and shell ----------------------------------------------------
    _rule("device_switcher", r"^sidebar_device_switcher_btn$", CONVERSATION_MODES, TAP,
          "sidebar_shell"),
    _rule("conversation_search_open", r"^conversation_search_button$",
          CONVERSATION_MODES, TAP, "sidebar_shell"),
    _rule("new_session", r"^sidebar_new_session_btn$", CONVERSATION_MODES, TAP,
          "sidebar_shell"),
    _rule("create_workspace", r"^sidebar_create_workspace_btn$", CONVERSATION_MODES, TAP,
          "sidebar_shell"),
    _rule("new_unscoped_conversation", r"^sidebar_new_unscoped_conversation_btn$",
          CONVERSATION_MODES, TAP, "sidebar_shell"),
    _rule("new_conversation", r"^sidebar_new_conversation_btn:", CONVERSATION_MODES, TAP,
          "sidebar_shell"),
    _rule("profile_destination", r"^sidebar_profile_destination$", CONVERSATION_MODES, TAP,
          "sidebar_shell"),
    _rule("general_settings_destination", r"^sidebar_general_settings_destination$",
          CONVERSATION_MODES, TAP, "sidebar_shell"),
    _rule("sidebar_toggle", r"^sidebar_toggle_btn$", CONVERSATION_MODES, TAP,
          "sidebar_shell"),
    _rule("compact_window", r"^desktop_compact_window_btn$", CONVERSATION_MODES, TAP,
          "sidebar_shell"),
    _rule("sidebar_back", r"^sidebar_back_btn$", CONVERSATION_MODES, TAP, "sidebar_shell"),
    _rule("workspace_group", r"^workspace-group:", CONVERSATION_MODES, TAP,
          "sidebar_workspace", tier=TIER_CHROME),
    _rule("workspace_settings", r"^workspace_settings_btn$", CONVERSATION_MODES, TAP,
          "sidebar_workspace", tier=TIER_CHROME),
    _rule("conversation_row", r"^(ws|unscoped):", CONVERSATION_MODES, TAP,
          "sidebar_conversation", tier=TIER_CHROME),
    _rule("conversation_row_menu", r"^StandardComponentType\.moreButton$",
          CONVERSATION_MODES, TAP, "sidebar_row_menu", tier=TIER_CHROME),
    _rule("load_more", r"^(workspace|unscoped)-load-more", CONVERSATION_MODES, TAP,
          "load_more", tier=TIER_CHROME),

    # --- permission card ------------------------------------------------------
    _rule("approve_once", r"^permission_option_once$", (PERMISSION_CARD,), TAP,
          "permission_option", irreversible=True,
          reason="grants a tool capability for the current request"),
    _rule("approve_session", r"^permission_option_session$", (PERMISSION_CARD,), TAP,
          "permission_option", irreversible=True,
          reason="grants a tool capability for the whole session"),
    _rule("approve_workspace", r"^permission_option_workspace$", (PERMISSION_CARD,), TAP,
          "permission_option", irreversible=True,
          reason="permanently approves the capability for this workspace"),
    _rule("deny_request", r"^permission_option_deny$", (PERMISSION_CARD,), TAP,
          "permission_option"),
    _rule("deny_comment", r"^permission_deny_comment_input$", (PERMISSION_CARD,), TYPE,
          "permission_option"),
    _rule("submit_denial", r"^permission_deny_submit_button$", (PERMISSION_CARD,), TAP,
          "permission_option",
          preconditions=(f"{FIELD_PRESENT}:permission_deny_comment_input",
                         f"{DETAIL_IS}:{PERMISSION_DENY_COMMENT}")),

    # --- ask_user card -------------------------------------------------------
    _rule("answer_option", r"^predefined_option_\d+$", (ASK_USER_CARD,), TAP,
          "ask_user_option"),
    _rule("custom_answer_option", r"^custom_answer_option$", (ASK_USER_CARD,), TAP,
          "ask_user_option"),
    _rule("custom_answer_input", r"^clarifying_question_input$", (ASK_USER_CARD,), TYPE,
          "ask_user_option"),
    _rule("submit_custom_answer", r"^submit_question_answer_btn$", (ASK_USER_CARD,), TAP,
          "ask_user_option",
          preconditions=(f"{FIELD_FILLED}:clarifying_question_input",
                         f"{DETAIL_IS}:{ASK_USER_CUSTOM_INPUT}")),
    _rule("back_to_options", r"^back_to_options_btn$", (ASK_USER_CARD,), TAP,
          "ask_user_option"),
    _rule("back_to_previous_question", r"^back_to_previous_question_btn$", (ASK_USER_CARD,),
          TAP, "ask_user_option"),
    _rule("skip_question", r"^skip_this_question_btn$", (ASK_USER_CARD,), TAP,
          "ask_user_option"),
    _rule("dismiss_questions", r"^dismiss_all_clarifying_questions_btn$", (ASK_USER_CARD,),
          TAP, "ask_user_option"),

    # --- model picker --------------------------------------------------------
    _rule("model_picker_search", r"^model_picker_search_input$", (MODEL_PICKER,), TYPE,
          "model_picker_chrome", tier=TIER_CHROME),
    _rule("model_picker_close", r"^model_picker_close_btn$", (MODEL_PICKER,), TAP,
          "model_picker_chrome", tier=TIER_CHROME),
    _rule("model_picker_refresh", r"^model_picker_refresh_btn$", (MODEL_PICKER,), TAP,
          "model_picker_chrome", tier=TIER_CHROME),
    _rule("model_picker_settings", r"^model_picker_settings_btn$", (MODEL_PICKER,), TAP,
          "model_picker_chrome", tier=TIER_CHROME),
    _rule("model_picker_load_more", r"^model_picker_load_more_", (MODEL_PICKER,), TAP,
          "model_picker_load_more", tier=TIER_CHROME),
    _rule("recent_model_option", r"^recent_model_option_", (MODEL_PICKER,), TAP,
          "model_option"),
    _rule("model_option", r"^model_option_", (MODEL_PICKER,), TAP, "model_option"),

    # --- composer popups -----------------------------------------------------
    _rule("permission_mode_default", r"^composer_permission_mode_default$",
          (COMPOSER_POPUP,), TAP, "permission_mode_option"),
    _rule("permission_mode_grant", r"^composer_permission_mode_(?!default$)",
          (COMPOSER_POPUP,), TAP, "permission_mode_option", irreversible=True,
          reason="changes the standing permission policy of the workspace"),
    _rule("thinking_mode_option", r"^thinking_mode_option_", (COMPOSER_POPUP,), TAP,
          "thinking_mode_option"),
    _rule("device_item", r"^sidebar_device_item_", (COMPOSER_POPUP,), TAP, "device_item"),
    _rule("device_management", r"^sidebar_device_management_btn$", (COMPOSER_POPUP,), TAP,
          "device_item"),

    # --- conversation search -------------------------------------------------
    _rule("conversation_search_field", r"^conversation_search_field$",
          (CONVERSATION_SEARCH,), TYPE, "search_chrome"),
    _rule("conversation_search_close", r"^conversation_search_close_btn$",
          (CONVERSATION_SEARCH,), TAP, "search_chrome"),
    _rule("conversation_search_result", r"^conversation_search_result:",
          (CONVERSATION_SEARCH,), TAP, "search_result"),

    # --- settings ------------------------------------------------------------
    _rule("settings_back", r"^settings_back_to_conversations_btn$", (SETTINGS,), TAP,
          "settings_nav", tier=TIER_CHROME),
    _rule("settings_nav_tile", r"^nav_tile_", (SETTINGS,), TAP, "settings_nav"),
    _rule("settings_nav_device", r"^nav_device_", (SETTINGS,), TAP, "settings_nav"),
    _rule("settings_nav_workspace", r"^nav_workspace_", (SETTINGS,), TAP, "settings_nav"),
    _rule("add_mcp_server", r"^add-mcp-server$", (SETTINGS,), TAP, "settings_mcp"),
    _rule("mcp_scope_segment", r"^mcp_scope_segment_btn$", (SETTINGS,), TAP, "settings_mcp"),
    _rule("mcp_server_row", r"^mcp-", (SETTINGS,), TAP, "settings_mcp"),
    _rule("add_provider", r"^add_provider_btn$", (SETTINGS,), TAP, "settings_provider"),
    _rule("provider_delete", r"^provider_instance_delete_", (SETTINGS,), TAP,
          "provider_instance", irreversible=True,
          reason="deletes a configured provider instance"),
    _rule("provider_action", r"^provider_instance_", (SETTINGS,), TAP,
          "provider_instance"),
    _rule("check_updates", r"^device_check_updates_button$", (SETTINGS,), TAP,
          "settings_device"),
    _rule("apply_update", r"^device_apply_update_button$", (SETTINGS,), TAP,
          "settings_device", irreversible=True,
          reason="installs an update and restarts the runtime"),
    _rule("restart_agent", r"^device_restart_agent_button$", (SETTINGS,), TAP,
          "settings_device", irreversible=True,
          reason="kills in-flight agent work and cannot be undone"),
    _rule("workspace_tab", r"^workspace_tab_", (SETTINGS,), TAP, "workspace_tab"),
    _rule("remove_workspace", r"^remove_workspace_button$", (SETTINGS,), TAP,
          "workspace_tab", irreversible=True,
          reason="removes a workspace registration"),
    _rule("workspace_execution_mode", r"^workspace_execution_mode_selector$", (SETTINGS,),
          TAP, "workspace_setting"),
    _rule("workspace_host_discovery", r"^workspace_host_discovery_selector$", (SETTINGS,),
          TAP, "workspace_setting"),
    _rule("sign_out", r"^sign_out_btn$", (SETTINGS,), TAP, "settings_profile",
          irreversible=True, reason="ends the authenticated session"),
    _rule("delete_account", r"^delete_account_btn$", (SETTINGS,), TAP, "settings_profile",
          irreversible=True, reason="permanently deletes the account"),
    _rule("client_cli_toggle", r"^client_cli_toggle_switch$", (SETTINGS,), TAP,
          "settings_general"),
    _rule("language_selector", r"^language_selector$", (SETTINGS,), TAP,
          "settings_general"),
    _rule("appearance_export", r"^appearance_export_btn$", (SETTINGS,), TAP,
          "settings_general"),
    _rule("appearance_import", r"^appearance_import_btn$", (SETTINGS,), TAP,
          "settings_general"),
    _rule("theme_style_selector", r"^theme_style_selector$", (SETTINGS,), TAP,
          "settings_general"),
    _rule("primary_color_selector", r"^primary_color_selector_", (SETTINGS,), TAP,
          "settings_general"),
    _rule("font_family_selector", r"^font_family_selector$", (SETTINGS,), TAP,
          "settings_general"),
    _rule("font_size_selector", r"^font_size_selector$", (SETTINGS,), TAP,
          "settings_general"),
    _rule("background_option", r"^background_option_", (SETTINGS,), TAP,
          "settings_appearance"),
)


def rule_for(key: str) -> Optional[ActionRule]:
    """Return the declared rule for one widget key, or ``None`` when undeclared."""
    for rule in ACTION_RULES:
        if rule.pattern.search(key):
            return rule
    return None


def rules_for_mode(mode: str) -> Tuple[ActionRule, ...]:
    return tuple(rule for rule in ACTION_RULES if mode in rule.modes)


_RULE_INDEX: Dict[str, ActionRule] = {rule.name: rule for rule in ACTION_RULES}


def rule_by_name(name: str) -> ActionRule:
    return _RULE_INDEX[name]
