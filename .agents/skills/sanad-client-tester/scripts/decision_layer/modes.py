"""Deterministic screen-mode classifier for the Sanad Client decision layer.

The classifier owns one job: name the live decision surface, or say ``unknown``.
It never guesses and never consults a model. Every mode is proven by keyed
widgets that exist in the current snapshot, so a classifier result can always be
explained by naming the keys that matched.

Mode precedence is overlay-first. Flutter keeps the route below the top one
alive, so a settings pane and the conversation composer can be present in the
same tree; the overlay or the top route always wins over the base screen.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence, Tuple

CONVERSATION_IDLE = "conversation_idle"
CONVERSATION_RUNNING = "conversation_running"
PERMISSION_CARD = "permission_card"
ASK_USER_CARD = "ask_user_card"
MODEL_PICKER = "model_picker"
COMPOSER_POPUP = "composer_popup"
CONVERSATION_SEARCH = "conversation_search"
SETTINGS = "settings"
UNKNOWN = "unknown"

KNOWN_MODES: Tuple[str, ...] = (
    CONVERSATION_IDLE,
    CONVERSATION_RUNNING,
    PERMISSION_CARD,
    ASK_USER_CARD,
    MODEL_PICKER,
    COMPOSER_POPUP,
    CONVERSATION_SEARCH,
    SETTINGS,
)

# Modes that own the screen and block the base surface underneath them.
OVERLAY_MODES: Tuple[str, ...] = (
    PERMISSION_CARD,
    ASK_USER_CARD,
    MODEL_PICKER,
    COMPOSER_POPUP,
)

# Per-mode detail values. A detail is a deterministic refinement of the mode, not
# a second classification: it is derived from the same key set.
PERMISSION_OPTIONS = "options"
PERMISSION_DENY_COMMENT = "deny_comment"

ASK_USER_OPTIONS = "options"
ASK_USER_CUSTOM_INPUT = "custom_input"

MODEL_PICKER_LIST = "list"
MODEL_PICKER_FILTERED = "filtered"

COMPOSER_PERMISSION_MODE = "permission_mode"
COMPOSER_THINKING_MODE = "thinking_mode"
COMPOSER_DEVICE_SWITCHER = "device_switcher"

SEARCH_EMPTY = "empty"
SEARCH_RESULTS = "results"


def _is_text_field(element: Mapping[str, Any]) -> bool:
    raw = element.get("type")
    base = str(raw).split("<", 1)[0].strip() if raw else ""
    return base in {"TextField", "TextFieldTapRegion"}


@dataclass(frozen=True)
class ModeEvidence:
    """A classification with the keys that justify it."""

    mode: str
    detail: str | None
    matched: Tuple[str, ...]
    blockers: Tuple[str, ...]

    @property
    def is_known(self) -> bool:
        return self.mode in KNOWN_MODES

    @property
    def is_overlay(self) -> bool:
        return self.mode in OVERLAY_MODES

    def to_dict(self) -> dict:
        return {
            "mode": self.mode,
            "detail": self.detail,
            "matched": list(self.matched),
            "blockers": list(self.blockers),
        }


def _element_keys(elements: Iterable[Mapping[str, Any]]) -> Tuple[Tuple[str, ...], dict]:
    keys: list[str] = []
    selected: dict[str, bool] = {}
    for element in elements:
        key = element.get("key")
        if not isinstance(key, str) or not key:
            continue
        keys.append(key)
        if element.get("selected") is True:
            selected[key] = True
    return tuple(keys), selected


def _first(keys: Sequence[str], predicate) -> str | None:
    for key in keys:
        if predicate(key):
            return key
    return None


def _permission(keys: Sequence[str]) -> str | None:
    found = _first(
        keys,
        lambda key: key.startswith("permission_option_")
        or key == "permission_deny_submit_button",
    )
    return found


def _ask_user(keys: Sequence[str]) -> str | None:
    return _first(
        keys,
        lambda key: key.startswith("predefined_option_")
        or key
        in {
            "custom_answer_option",
            "clarifying_question_input",
            "submit_question_answer_btn",
            "back_to_options_btn",
        },
    )


def _model_picker(keys: Sequence[str]) -> str | None:
    return _first(
        keys,
        lambda key: key
        in {"model_picker_search_input", "model_picker_close_btn"}
        or key.startswith("model_option_")
        or key.startswith("recent_model_option_"),
    )


def _composer_popup(keys: Sequence[str]) -> str | None:
    return _first(
        keys,
        lambda key: key.startswith("composer_permission_mode_")
        or key.startswith("thinking_mode_option_")
        or key.startswith("sidebar_device_item_"),
    )


def _conversation_search(keys: Sequence[str]) -> str | None:
    return _first(
        keys,
        lambda key: key == "conversation_search_field"
        or key.startswith("conversation_search_result:"),
    )


def _settings(keys: Sequence[str]) -> str | None:
    return _first(
        keys,
        lambda key: key == "settings_back_to_conversations_btn"
        or key.startswith("nav_tile_")
        or key.startswith("nav_device_")
        or key.startswith("nav_workspace_"),
    )


def _conversation(keys: Sequence[str]) -> str | None:
    if "stop_message_btn" in keys:
        return "stop_message_btn"
    return _first(keys, lambda key: key in {"chat_input", "send_message_btn"})


def _permission_detail(keys: Sequence[str]) -> str:
    if "permission_deny_comment_input" in keys or "permission_deny_submit_button" in keys:
        return PERMISSION_DENY_COMMENT
    return PERMISSION_OPTIONS


def _ask_user_detail(keys: Sequence[str]) -> str:
    if "clarifying_question_input" in keys or "back_to_options_btn" in keys:
        return ASK_USER_CUSTOM_INPUT
    return ASK_USER_OPTIONS


def _model_picker_detail(
    keys: Sequence[str], fields: Mapping[str, bool]
) -> str:
    if fields.get("model_picker_search_input"):
        return MODEL_PICKER_FILTERED
    return MODEL_PICKER_LIST


def _composer_popup_detail(keys: Sequence[str]) -> str:
    if _first(keys, lambda key: key.startswith("composer_permission_mode_")):
        return COMPOSER_PERMISSION_MODE
    if _first(keys, lambda key: key.startswith("thinking_mode_option_")):
        return COMPOSER_THINKING_MODE
    return COMPOSER_DEVICE_SWITCHER


def _search_detail(keys: Sequence[str]) -> str:
    if _first(keys, lambda key: key.startswith("conversation_search_result:")):
        return SEARCH_RESULTS
    return SEARCH_EMPTY


# Ordered page markers for the settings mode. A marker proves which settings pane
# is rendered, which is stronger evidence than the selected navigation tile.
_SETTINGS_PAGE_MARKERS: Tuple[Tuple[str, Tuple[str, ...]], ...] = (
    ("profile", ("delete_account_btn", "sign_out_btn")),
    ("mcp_servers", ("add-mcp-server", "mcp_scope_segment_btn")),
    ("providers", ("add_provider_btn", "provider_instance_")),
    (
        "device",
        (
            "device_restart_agent_button",
            "device_apply_update_button",
            "device_check_updates_button",
        ),
    ),
    ("workspace", ("workspace_tab_", "remove_workspace_button")),
    (
        "general",
        (
            "client_cli_toggle_switch",
            "language_selector",
            "appearance_",
            "theme_style_selector",
            "font_",
            "background_option_",
        ),
    ),
)


def _settings_detail(keys: Sequence[str], selected: Mapping[str, bool]) -> str:
    for detail, markers in _SETTINGS_PAGE_MARKERS:
        if _first(
            keys,
            lambda key, markers=markers: any(
                key == marker or key.startswith(marker) for marker in markers
            ),
        ):
            return detail
    chosen = _first(
        keys, lambda key: key.startswith("nav_tile_") and selected.get(key, False)
    )
    if chosen is not None:
        return chosen[len("nav_tile_") :]
    return "navigation"


def classify(elements: Iterable[Mapping[str, Any]]) -> ModeEvidence:
    """Return the current screen mode with the keys that prove it."""
    materialized = tuple(elements)
    keys, selected = _element_keys(materialized)
    fields = {
        str(element.get("key")): bool(
            " ".join(str(element.get("text") or "").split())
        )
        for element in materialized
        if _is_text_field(element) and isinstance(element.get("key"), str)
    }

    candidates: Tuple[Tuple[str, str | None, str | None], ...] = (
        (PERMISSION_CARD, _permission(keys), _permission_detail(keys)),
        (ASK_USER_CARD, _ask_user(keys), _ask_user_detail(keys)),
        (MODEL_PICKER, _model_picker(keys), _model_picker_detail(keys, fields)),
        (COMPOSER_POPUP, _composer_popup(keys), _composer_popup_detail(keys)),
        (
            CONVERSATION_SEARCH,
            _conversation_search(keys),
            _search_detail(keys),
        ),
        (SETTINGS, _settings(keys), _settings_detail(keys, selected)),
        (CONVERSATION_RUNNING, "stop_message_btn" if "stop_message_btn" in keys else None, None),
        (
            CONVERSATION_IDLE,
            _first(keys, lambda key: key in {"chat_input", "send_message_btn"}),
            None,
        ),
    )

    present = tuple(
        (mode, marker) for mode, marker, _detail in candidates if marker is not None
    )
    blockers = tuple(mode for mode, _ in present if mode in OVERLAY_MODES)

    for mode, marker, detail in candidates:
        if marker is None:
            continue
        matched = (marker,)
        if mode == SETTINGS:
            matched = tuple(
                key
                for key in keys
                if key == "settings_back_to_conversations_btn"
                or key.startswith(("nav_tile_", "nav_device_", "nav_workspace_"))
            )[:5]
        if mode == CONVERSATION_RUNNING:
            detail = None
        return ModeEvidence(
            mode=mode,
            detail=detail,
            matched=matched,
            blockers=tuple(blocker for blocker in blockers if blocker != mode),
        )

    return ModeEvidence(mode=UNKNOWN, detail=None, matched=(), blockers=blockers)
