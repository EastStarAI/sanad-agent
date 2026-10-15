#!/usr/bin/env python3
"""Run one parameterized Sanad conversation workflow through ``sanad-dev ui``.

Deterministic code owns workflow order, exact selectors, one-shot phases, event
waiting, and return navigation. Jev is used only for a narrow semantic judgment
of the newly rendered assistant response.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, Iterable, Mapping, Sequence

def _find_repo_root() -> Path:
    for candidate in Path(__file__).resolve().parents:
        if (candidate / "AGENTS.md").is_file() and (candidate / ".agents").is_dir():
            return candidate
    raise RuntimeError("Could not locate the Sanad repository root")


REPO_ROOT = _find_repo_root()
JEV_SCRIPTS = REPO_ROOT / ".agents/skills/jev-dual-brain-automation/scripts"
if str(JEV_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(JEV_SCRIPTS))

from jev_client import JevClient  # noqa: E402
from workflow_engine import PhaseLedger  # noqa: E402

DEVICE_SELECTOR_TYPE = "PopupMenuButton<Object?>"
DEVICE_KEY_PREFIX = "sidebar_device_item_"
USER_BODY_PREFIX = "user_message_body:"
ASSISTANT_BODY_PREFIX = "assistant_message_body:"
MODEL_SELECTOR_KEY = "model_selector_btn"
MODEL_SEARCH_KEY = "model_picker_search_input"
CHAT_INPUT_KEY = "chat_input"
SEND_KEY = "send_message_btn"
STOP_KEY = "stop_message_btn"
NEW_UNSCOPED_KEY = "sidebar_new_unscoped_conversation_btn"


class WorkflowError(RuntimeError):
    """A fail-closed workflow error safe to print without secrets."""


@dataclass(frozen=True)
class ConversationTarget:
    kind: str
    value: str | None = None
    workspace_name: str | None = None


@dataclass(frozen=True)
class Origin:
    conversation_key: str
    device_name: str


@dataclass(frozen=True)
class RunResult:
    user_event_key: str | None
    assistant_event_key: str
    assistant_text: str
    jev_probability: float
    returned_to_origin: bool


class UI:
    def __init__(self, command_timeout: int = 40) -> None:
        self.command_timeout = command_timeout

    def run(
        self,
        *args: str,
        timeout: int | None = None,
        allow_failure: bool = False,
    ) -> str:
        process = subprocess.run(
            ["sanad-dev", "ui", *args],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout or self.command_timeout,
        )
        if process.returncode and not allow_failure:
            detail = process.stderr.strip() or process.stdout.strip()
            raise WorkflowError(detail or f"sanad-dev ui {args[0]} failed")
        return process.stdout.strip()

    def snapshot(self) -> list[dict[str, Any]]:
        raw = self.run("snapshot", "--interactive", "--compact", "--json")
        try:
            payload = json.loads(raw)
            elements = payload["elements"]
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            raise WorkflowError("sanad-dev returned a malformed snapshot") from error
        if not isinstance(elements, list):
            raise WorkflowError("Snapshot elements are not a list")
        return [item for item in elements if isinstance(item, dict)]

    def batch(
        self, steps: Sequence[Mapping[str, Any]], *, timeout: int
    ) -> dict[str, Any]:
        raw = self.run(
            "batch",
            "--json-steps",
            json.dumps(list(steps), ensure_ascii=False),
            "--json",
            timeout=timeout,
        )
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise WorkflowError("sanad-dev ui batch returned invalid JSON") from error
        if payload.get("status") != "ok":
            failed = [
                result.get("message")
                for result in payload.get("results", [])
                if isinstance(result, dict) and result.get("success") is not True
            ]
            raise WorkflowError(
                "UI batch failed: " + "; ".join(str(value) for value in failed)
            )
        return payload

    def find_key(self, key: str) -> dict[str, Any] | None:
        payload = self._json("find", "--key", key, "--json", allow_failure=True)
        elements = payload.get("elements")
        if payload.get("found") is True and isinstance(elements, list) and len(elements) == 1:
            element = elements[0]
            return element if isinstance(element, dict) else None
        return None

    def _json(
        self, *args: str, allow_failure: bool = False
    ) -> dict[str, Any]:
        raw = self.run(*args, allow_failure=allow_failure)
        if not raw:
            return {}
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise WorkflowError(f"sanad-dev ui {args[0]} returned invalid JSON") from error
        if not isinstance(payload, dict):
            raise WorkflowError(f"sanad-dev ui {args[0]} returned a non-object")
        return payload


def exact_elements(
    elements: Iterable[Mapping[str, Any]],
    *,
    key: str | None = None,
    text: str | None = None,
    element_type: str | None = None,
) -> list[Mapping[str, Any]]:
    return [
        item
        for item in elements
        if (key is None or item.get("key") == key)
        and (text is None or item.get("text") == text)
        and (element_type is None or item.get("type") == element_type)
    ]


def event_bodies(
    elements: Iterable[Mapping[str, Any]], prefix: str
) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in elements:
        key = item.get("key")
        text = item.get("text")
        if isinstance(key, str) and key.startswith(prefix) and isinstance(text, str):
            result[key] = text
    return result


def selected_conversation_key(elements: Iterable[Mapping[str, Any]]) -> str:
    selected = [
        str(item["key"])
        for item in elements
        if item.get("type") == "SidebarConversationRow"
        and item.get("selected") is True
        and isinstance(item.get("key"), str)
        and str(item["key"]).startswith(("ws:", "unscoped:"))
    ]
    if len(selected) != 1:
        raise WorkflowError(
            "Cannot capture one selected origin conversation; supply a stable starting conversation"
        )
    return selected[0]


def conversation_key_for_id(
    elements: Iterable[Mapping[str, Any]], conversation_id: str
) -> str:
    suffix = f":{conversation_id}"
    matches = [
        str(item["key"])
        for item in elements
        if item.get("type") == "SidebarConversationRow"
        and isinstance(item.get("key"), str)
        and (
            item["key"] == f"unscoped:{conversation_id}"
            or str(item["key"]).endswith(suffix)
        )
    ]
    if len(matches) != 1:
        raise WorkflowError(
            f"Expected one visible conversation id {conversation_id!r}, found {len(matches)}"
        )
    return matches[0]


def conversation_key_for_title(
    elements: Iterable[Mapping[str, Any]], title: str
) -> str:
    matches = [
        str(item["key"])
        for item in elements
        if item.get("type") == "SidebarConversationRow"
        and item.get("text") == title
        and isinstance(item.get("key"), str)
    ]
    if len(matches) != 1:
        raise WorkflowError(
            f"Expected one visible conversation titled {title!r}, found {len(matches)}"
        )
    return matches[0]


def new_conversation_key(workspace_id: str | None = None) -> str:
    if workspace_id:
        return f"sidebar_new_conversation_btn:{workspace_id}"
    return NEW_UNSCOPED_KEY


def workspace_id_for_name(
    elements: Iterable[Mapping[str, Any]], workspace_name: str
) -> str:
    matches = [
        str(item["key"]).removeprefix("workspace-group:")
        for item in elements
        if item.get("type") == "SidebarWorkspaceGroupTile"
        and item.get("text") == workspace_name
        and isinstance(item.get("key"), str)
        and str(item["key"]).startswith("workspace-group:")
    ]
    if len(matches) != 1:
        raise WorkflowError(
            f"Expected one visible workspace named {workspace_name!r}, found {len(matches)}"
        )
    return matches[0]


def parse_target(args: argparse.Namespace) -> ConversationTarget:
    if args.new_conversation:
        return ConversationTarget("new", workspace_name=args.workspace)
    if args.conversation_id:
        return ConversationTarget("id", args.conversation_id)
    return ConversationTarget("title", args.conversation_title)


class ConversationRunner:
    def __init__(self, ui: UI, jev: JevClient, response_timeout: int) -> None:
        self.ui = ui
        self.jev = jev
        self.response_timeout = response_timeout
        self.phases = PhaseLedger()

    def run(
        self,
        *,
        device: str,
        conversation: ConversationTarget,
        provider: str,
        model: str,
        message: str,
        return_device: str | None,
        leave_at_target: bool,
    ) -> RunResult:
        initial = self.ui.snapshot()
        origin_key = selected_conversation_key(initial)
        if not leave_at_target and not return_device:
            raise WorkflowError(
                "Return is enabled, so --return-device must name the current origin device"
            )
        origin = Origin(origin_key, return_device or "")

        result: RunResult | None = None
        primary_error: Exception | None = None
        try:
            required_devices = () if leave_at_target else (origin.device_name,)
            self._switch_device(
                device,
                phase="select_target_device",
                required_devices=required_devices,
            )
            if not leave_at_target and device != origin.device_name:
                if self.ui.find_key(origin.conversation_key) is not None:
                    raise WorkflowError(
                        "Origin conversation remained visible after target-device selection"
                    )
            self._open_conversation(conversation)
            self._select_model(provider, model)

            before_send = self.ui.snapshot()
            baseline_users = event_bodies(before_send, USER_BODY_PREFIX)
            baseline_assistants = event_bodies(before_send, ASSISTANT_BODY_PREFIX)
            self._enter_message(message, before_send)
            completed = self._send_once_and_wait(message)
            user_key, assistant_key, assistant_text = self._extract_response(
                completed, message, baseline_users, baseline_assistants
            )
            probability = self._verify_response_semantics(message, assistant_text)
            result = RunResult(
                user_event_key=user_key,
                assistant_event_key=assistant_key,
                assistant_text=assistant_text,
                jev_probability=probability,
                returned_to_origin=leave_at_target,
            )
        except Exception as error:
            primary_error = error

        return_error: Exception | None = None
        if not leave_at_target:
            try:
                self._return_origin(origin)
            except Exception as error:
                return_error = error

        if primary_error is not None:
            if return_error is not None:
                raise WorkflowError(
                    f"{primary_error}; automatic return also failed: {return_error}"
                ) from primary_error
            raise primary_error
        if return_error is not None:
            raise return_error
        if result is None:
            raise WorkflowError("Workflow ended without a result")
        return RunResult(
            user_event_key=result.user_event_key,
            assistant_event_key=result.assistant_event_key,
            assistant_text=result.assistant_text,
            jev_probability=result.jev_probability,
            returned_to_origin=not leave_at_target,
        )

    def _switch_device(
        self,
        name: str,
        *,
        phase: str,
        required_devices: Sequence[str] = (),
    ) -> None:
        self.phases.begin(phase, irreversible=False)
        current = self.ui.snapshot()
        if len(exact_elements(current, element_type=DEVICE_SELECTOR_TYPE)) != 1:
            raise WorkflowError("Expected one visible device selector")
        key = f"{DEVICE_KEY_PREFIX}{name}"
        steps: list[dict[str, Any]] = [
            {"action": "tap", "type": DEVICE_SELECTOR_TYPE, "index": 0, "delay_ms": 80},
        ]
        for required in dict.fromkeys((name, *required_devices)):
            steps.append(
                {
                    "action": "wait_for",
                    "key": f"{DEVICE_KEY_PREFIX}{required}",
                    "timeout": 10,
                }
            )
        steps.extend(
            [
                {"action": "tap", "key": key, "delay_ms": 80},
                {"action": "wait_for", "key": CHAT_INPUT_KEY, "timeout": 20},
            ]
        )
        self.ui.batch(steps, timeout=50)
        self.phases.complete(phase)

    def _open_conversation(self, target: ConversationTarget) -> None:
        phase = "create_conversation" if target.kind == "new" else "open_conversation"
        irreversible = target.kind == "new"
        self.phases.begin(phase, irreversible=irreversible)
        elements = self.ui.snapshot()
        if target.kind == "new":
            workspace_id = None
            if target.workspace_name:
                workspace_id = workspace_id_for_name(elements, target.workspace_name)
                selected_rows = [
                    item
                    for item in elements
                    if item.get("type") == "SidebarConversationRow"
                    and item.get("selected") is True
                ]
                selected_workspace = exact_elements(
                    elements,
                    key="workspace_selector_btn",
                    text=target.workspace_name,
                )
                if not selected_rows and len(selected_workspace) == 1:
                    self.phases.complete(phase)
                    return
            key = new_conversation_key(workspace_id)
        elif target.kind == "id":
            key = conversation_key_for_id(elements, target.value or "")
        else:
            key = conversation_key_for_title(elements, target.value or "")
        if len(exact_elements(elements, key=key)) != 1:
            raise WorkflowError(f"Conversation target {key!r} is not currently visible")
        self.ui.batch(
            [
                {"action": "tap", "key": key, "delay_ms": 80},
                {"action": "wait_for", "key": CHAT_INPUT_KEY, "timeout": 20},
            ],
            timeout=35,
        )
        if target.kind != "new":
            selected = selected_conversation_key(self.ui.snapshot())
            if selected != key:
                raise WorkflowError(
                    f"Conversation selection failed: expected {key!r}, got {selected!r}"
                )
        elif target.workspace_name:
            workspace = exact_elements(
                self.ui.snapshot(),
                key="workspace_selector_btn",
                text=target.workspace_name,
            )
            if len(workspace) != 1:
                raise WorkflowError(
                    f"New conversation did not select workspace {target.workspace_name!r}"
                )
        self.phases.complete(phase)

    def _select_model(self, provider: str, model: str) -> None:
        self.phases.begin("select_model", irreversible=False)
        expected = f"{provider} | {model}"
        initial = self.ui.snapshot()
        current_matches = exact_elements(initial, key=MODEL_SELECTOR_KEY)
        if len(current_matches) != 1:
            raise WorkflowError("Model selector is unavailable or duplicated")
        current = current_matches[0]
        if current.get("text") != expected:
            self.ui.batch(
                [
                    {"action": "tap", "key": MODEL_SELECTOR_KEY, "delay_ms": 80},
                    {"action": "wait_for", "key": MODEL_SEARCH_KEY, "timeout": 10},
                ],
                timeout=25,
            )
            active_provider_matches = str(current.get("text", "")).startswith(
                f"{provider} | "
            )
            options = self.ui.snapshot()
            choice = self._exact_model_option(
                options,
                provider,
                model,
                active_provider_matches=active_provider_matches,
            )
            if choice is None:
                self.ui.batch(
                    [
                        {
                            "action": "enter_text",
                            "key": MODEL_SEARCH_KEY,
                            "text": model,
                            "delay_ms": 80,
                        }
                    ],
                    timeout=20,
                )
                options = self.ui.snapshot()
                choice = self._exact_model_option(
                    options,
                    provider,
                    model,
                    active_provider_matches=active_provider_matches,
                )
            if choice is None:
                raise WorkflowError(f"Exact model option {provider} / {model} was not found")
            self.ui.batch(
                [
                    {"action": "tap", "key": choice, "delay_ms": 80},
                    {"action": "wait_for", "key": MODEL_SELECTOR_KEY, "timeout": 15},
                ],
                timeout=30,
            )
        selected_matches = exact_elements(self.ui.snapshot(), key=MODEL_SELECTOR_KEY)
        selected = selected_matches[0] if len(selected_matches) == 1 else None
        if selected is None or selected.get("text") != expected:
            actual = None if selected is None else selected.get("text")
            raise WorkflowError(f"Model verification failed: expected {expected!r}, got {actual!r}")
        self.phases.complete("select_model")

    @staticmethod
    def _exact_model_option(
        elements: Iterable[Mapping[str, Any]],
        provider: str,
        model: str,
        *,
        active_provider_matches: bool = False,
    ) -> str | None:
        items = list(elements)
        expected_text = f"{provider} / {model}"
        recent = [
            str(item["key"])
            for item in items
            if item.get("type") == "ListTile"
            and item.get("text") == expected_text
            and isinstance(item.get("key"), str)
            and str(item["key"]).startswith("recent_model_option_")
        ]
        if len(recent) > 1:
            raise WorkflowError(f"Multiple exact recent models found for {expected_text!r}")
        if recent:
            return recent[0]

        provider_visible = any(item.get("text") == provider for item in items)
        grouped = [
            str(item["key"])
            for item in items
            if item.get("type") == "ListTile"
            and item.get("text") == model
            and item.get("key") == f"model_option_{model}"
        ]
        if (provider_visible or active_provider_matches) and len(grouped) == 1:
            return grouped[0]
        if len(grouped) > 1:
            raise WorkflowError(f"Model {model!r} is ambiguous across provider groups")
        return None

    def _enter_message(
        self, message: str, before_send: Sequence[Mapping[str, Any]]
    ) -> None:
        self.phases.begin("enter_message", irreversible=False)
        fields = exact_elements(before_send, key=CHAT_INPUT_KEY)
        if len(fields) != 1:
            raise WorkflowError("Chat input is unavailable or duplicated")
        existing = fields[0].get("text")
        if existing not in (None, ""):
            raise WorkflowError("Chat input is not empty; refusing to overwrite a draft")
        self.ui.batch(
            [
                {
                    "action": "enter_text",
                    "key": CHAT_INPUT_KEY,
                    "text": message,
                    "delay_ms": 80,
                },
                {"action": "wait_for", "key": SEND_KEY, "timeout": 10},
            ],
            timeout=25,
        )
        verified = exact_elements(self.ui.snapshot(), key=CHAT_INPUT_KEY)
        if len(verified) != 1 or verified[0].get("text") != message:
            raise WorkflowError("Exact message text was not preserved in chat_input")
        self.phases.complete("enter_message")

    def _send_once_and_wait(self, message: str) -> list[dict[str, Any]]:
        self.phases.begin("send_message", irreversible=True)
        payload = self.ui.batch(
            [
                {"action": "tap", "key": SEND_KEY, "delay_ms": 80},
                {"action": "wait_for", "text": message, "timeout": 20},
                {"action": "wait_for", "key": STOP_KEY, "timeout": 20},
                {
                    "action": "wait_for",
                    "key": STOP_KEY,
                    "absent": True,
                    "timeout": self.response_timeout,
                },
                {"action": "message_bodies"},
            ],
            timeout=self.response_timeout + 60,
        )
        self.phases.complete("send_message")
        results = payload.get("results")
        if not isinstance(results, list) or not results:
            raise WorkflowError("Send batch returned no inspection evidence")
        data = results[-1].get("data") if isinstance(results[-1], dict) else None
        elements = data.get("elements") if isinstance(data, dict) else None
        if not isinstance(elements, list):
            raise WorkflowError("Send batch returned malformed message-body evidence")
        return [item for item in elements if isinstance(item, dict)]

    def _extract_response(
        self,
        completed: Sequence[Mapping[str, Any]],
        message: str,
        baseline_users: Mapping[str, str],
        baseline_assistants: Mapping[str, str],
    ) -> tuple[str | None, str, str]:
        users = event_bodies(completed, USER_BODY_PREFIX)
        assistants = event_bodies(completed, ASSISTANT_BODY_PREFIX)
        normalized_message = " ".join(message.split())
        new_users = [
            (key, text)
            for key, text in users.items()
            if key not in baseline_users and " ".join(text.split()) == normalized_message
        ]
        new_assistants = [
            (key, text.strip())
            for key, text in assistants.items()
            if key not in baseline_assistants and text.strip()
        ]
        if len(new_users) > 1:
            raise WorkflowError(
                f"Expected at most one new exact user message event, found {len(new_users)}"
            )
        if not new_assistants:
            raise WorkflowError("No new non-empty assistant response event was rendered")
        assistant_key, assistant_text = new_assistants[-1]
        user_key = new_users[0][0] if new_users else None
        return user_key, assistant_key, assistant_text

    def _verify_response_semantics(self, message: str, response: str) -> float:
        result = self.jev.ask(
            state={
                "goal": "Verify that the new assistant response addresses the sent user request",
                "user_message": message,
                "assistant_response": response,
                "evidence": "Both texts came from new event-scoped Sanad message-body keys after one send",
            },
            questions={
                "addresses_request": {
                    "type": "noul",
                    "instructions": (
                        "Does the assistant response meaningfully answer or directly address "
                        "the user message, rather than being empty, unrelated, or only a status?"
                    ),
                }
            },
        )
        probability = result.answer("addresses_request", "noul").noul or 0.0
        if probability < 0.75:
            raise WorkflowError(
                f"Jev semantic response verification was too weak: {probability:.2f}"
            )
        return probability

    def _return_origin(self, origin: Origin) -> None:
        self.phases.begin("return_device", irreversible=False)
        self.phases.begin("return_conversation", irreversible=False)
        current = self.ui.snapshot()
        selected_keys = {
            str(item.get("key"))
            for item in current
            if item.get("type") == "SidebarConversationRow"
            and item.get("selected") is True
        }
        if origin.conversation_key in selected_keys:
            self.phases.complete("return_device")
            self.phases.complete("return_conversation")
            return
        if len(exact_elements(current, key="model_picker_close_btn")) == 1:
            self.ui.batch(
                [
                    {
                        "action": "tap",
                        "key": "model_picker_close_btn",
                        "delay_ms": 80,
                    }
                ],
                timeout=20,
            )
            current = self.ui.snapshot()
        if len(exact_elements(current, element_type=DEVICE_SELECTOR_TYPE)) != 1:
            raise WorkflowError("Expected one device selector before return")
        device_key = f"{DEVICE_KEY_PREFIX}{origin.device_name}"
        self.ui.batch(
            [
                {
                    "action": "tap",
                    "type": DEVICE_SELECTOR_TYPE,
                    "index": 0,
                    "delay_ms": 80,
                },
                {"action": "wait_for", "key": device_key, "timeout": 10},
                {"action": "tap", "key": device_key, "delay_ms": 80},
                {
                    "action": "wait_for",
                    "key": origin.conversation_key,
                    "timeout": 30,
                },
                {
                    "action": "tap",
                    "key": origin.conversation_key,
                    "delay_ms": 80,
                },
                {"action": "wait_for", "key": CHAT_INPUT_KEY, "timeout": 20},
            ],
            timeout=80,
        )
        selected = selected_conversation_key(self.ui.snapshot())
        if selected != origin.conversation_key:
            raise WorkflowError(
                "Return verification failed: expected "
                f"{origin.conversation_key!r}, selected {selected!r}"
            )
        self.phases.complete("return_device")
        self.phases.complete("return_conversation")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Send one message through a selected Sanad device/conversation/model, "
            "verify the new response with Jev, and optionally return to origin."
        )
    )
    parser.add_argument("--device", required=True, help="Exact target device name")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--new-conversation", action="store_true")
    target.add_argument("--conversation-id")
    target.add_argument("--conversation-title")
    parser.add_argument(
        "--workspace",
        help="Exact workspace name for a new conversation only",
    )
    parser.add_argument("--provider", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument(
        "--return-device",
        help="Exact origin device name; required unless --leave-at-target is used",
    )
    parser.add_argument(
        "--leave-at-target",
        action="store_true",
        help="Do not return to the originally selected conversation",
    )
    parser.add_argument("--response-timeout", type=int, default=180)
    return parser


def validate_args(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    if args.workspace and not args.new_conversation:
        parser.error("--workspace is valid only with --new-conversation")
    if not args.leave_at_target and not args.return_device:
        parser.error("--return-device is required unless --leave-at-target is used")
    if args.response_timeout < 10:
        parser.error("--response-timeout must be at least 10 seconds")


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_args(parser, args)
    try:
        runner = ConversationRunner(UI(), JevClient(), args.response_timeout)
        result = runner.run(
            device=args.device,
            conversation=parse_target(args),
            provider=args.provider,
            model=args.model,
            message=args.message,
            return_device=args.return_device,
            leave_at_target=args.leave_at_target,
        )
    except Exception as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "status": "success",
                "user_event_key": result.user_event_key,
                "assistant_event_key": result.assistant_event_key,
                "jev_response_probability": round(result.jev_probability, 4),
                "assistant_response": result.assistant_text,
                "returned_to_origin": result.returned_to_origin,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
