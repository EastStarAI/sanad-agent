from __future__ import annotations

import argparse
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import sanad_conversation_workflow as runner  # noqa: E402


class SelectorTests(unittest.TestCase):
    def test_selected_conversation_key_requires_one_selected_row(self) -> None:
        elements = [
            {
                "type": "SidebarConversationRow",
                "key": "ws:workspace-1:conversation-1",
                "selected": True,
            },
            {
                "type": "SidebarConversationRow",
                "key": "unscoped:conversation-2",
                "selected": False,
            },
        ]
        self.assertEqual(
            runner.selected_conversation_key(elements),
            "ws:workspace-1:conversation-1",
        )

    def test_conversation_id_matches_scoped_or_unscoped_key(self) -> None:
        scoped = [
            {
                "type": "SidebarConversationRow",
                "key": "ws:workspace-1:conversation-1",
            }
        ]
        unscoped = [
            {
                "type": "SidebarConversationRow",
                "key": "unscoped:conversation-2",
            }
        ]
        self.assertEqual(
            runner.conversation_key_for_id(scoped, "conversation-1"),
            "ws:workspace-1:conversation-1",
        )
        self.assertEqual(
            runner.conversation_key_for_id(unscoped, "conversation-2"),
            "unscoped:conversation-2",
        )

    def test_duplicate_title_fails_closed(self) -> None:
        elements = [
            {"type": "SidebarConversationRow", "key": "unscoped:1", "text": "Same"},
            {"type": "SidebarConversationRow", "key": "unscoped:2", "text": "Same"},
        ]
        with self.assertRaises(runner.WorkflowError):
            runner.conversation_key_for_title(elements, "Same")

    def test_event_bodies_keep_only_matching_prefix(self) -> None:
        elements = [
            {"key": "user_message_body:event-1", "text": "hello"},
            {"key": "assistant_message_body:event-2", "text": "world"},
            {"key": "assistant_message_body:event-3", "text": None},
        ]
        self.assertEqual(
            runner.event_bodies(elements, runner.ASSISTANT_BODY_PREFIX),
            {"assistant_message_body:event-2": "world"},
        )

    def test_exact_model_option_uses_provider_and_model_text(self) -> None:
        elements = [
            {
                "type": "ListTile",
                "key": "recent_model_option_kimi-k2.6",
                "text": "OpenCode Go / kimi-k2.6",
            },
            {
                "type": "ListTile",
                "key": "model_option_kimi-k2.7-code",
                "text": "kimi-k2.7-code",
            },
        ]
        self.assertEqual(
            runner.ConversationRunner._exact_model_option(
                elements, "OpenCode Go", "kimi-k2.6"
            ),
            "recent_model_option_kimi-k2.6",
        )

    def test_exact_grouped_model_requires_visible_provider(self) -> None:
        elements = [
            {"type": "Text", "text": "OpenCode Go"},
            {
                "type": "ListTile",
                "key": "model_option_deepseek-v4-flash",
                "text": "deepseek-v4-flash",
            },
        ]
        self.assertEqual(
            runner.ConversationRunner._exact_model_option(
                elements, "OpenCode Go", "deepseek-v4-flash"
            ),
            "model_option_deepseek-v4-flash",
        )

    def test_exact_grouped_model_accepts_verified_active_provider(self) -> None:
        elements = [
            {
                "type": "ListTile",
                "key": "model_option_deepseek-v4-flash",
                "text": "deepseek-v4-flash",
            }
        ]
        self.assertEqual(
            runner.ConversationRunner._exact_model_option(
                elements,
                "OpenCode Go",
                "deepseek-v4-flash",
                active_provider_matches=True,
            ),
            "model_option_deepseek-v4-flash",
        )

    def test_workspace_name_resolves_dynamic_new_conversation_key(self) -> None:
        elements = [
            {
                "type": "SidebarWorkspaceGroupTile",
                "key": "workspace-group:workspace-1",
                "text": "sanad-agent",
            }
        ]
        workspace_id = runner.workspace_id_for_name(elements, "sanad-agent")
        self.assertEqual(workspace_id, "workspace-1")
        self.assertEqual(
            runner.new_conversation_key(workspace_id),
            "sidebar_new_conversation_btn:workspace-1",
        )

    def test_parse_new_target(self) -> None:
        args = argparse.Namespace(
            new_conversation=True,
            conversation_id=None,
            conversation_title=None,
            workspace="sanad-agent",
        )
        self.assertEqual(
            runner.parse_target(args),
            runner.ConversationTarget("new", workspace_name="sanad-agent"),
        )

    def test_extract_response_accepts_missing_user_body_after_batch_text_wait(self) -> None:
        workflow = runner.ConversationRunner.__new__(runner.ConversationRunner)
        completed = [
            {
                "key": "assistant_message_body:assistant-1",
                "text": "تم التنفيذ بنجاح.",
            }
        ]
        self.assertEqual(
            workflow._extract_response(completed, "نفذ المهمة", {}, {}),
            (
                None,
                "assistant_message_body:assistant-1",
                "تم التنفيذ بنجاح.",
            ),
        )

    def test_automatic_return_runs_after_primary_verification_error(self) -> None:
        class FakeUI:
            def snapshot(self):
                return [
                    {
                        "type": "SidebarConversationRow",
                        "key": "unscoped:origin",
                        "selected": True,
                    }
                ]

            def find_key(self, key):
                return None

        workflow = runner.ConversationRunner(FakeUI(), object(), 30)
        workflow._switch_device = lambda *args, **kwargs: None
        workflow._open_conversation = lambda *args, **kwargs: None
        workflow._select_model = lambda *args, **kwargs: None
        workflow._enter_message = lambda *args, **kwargs: None
        workflow._send_once_and_wait = lambda *args, **kwargs: []
        workflow._extract_response = lambda *args, **kwargs: (_ for _ in ()).throw(
            runner.WorkflowError("verification failed")
        )
        returned = []
        workflow._return_origin = lambda origin: returned.append(origin)

        with self.assertRaisesRegex(runner.WorkflowError, "verification failed"):
            workflow.run(
                device="target",
                conversation=runner.ConversationTarget("new"),
                provider="provider",
                model="model",
                message="message",
                return_device="origin-device",
                leave_at_target=False,
            )
        self.assertEqual(
            returned,
            [runner.Origin("unscoped:origin", "origin-device")],
        )

    def test_extract_response_normalizes_rendered_user_whitespace(self) -> None:
        workflow = runner.ConversationRunner.__new__(runner.ConversationRunner)
        completed = [
            {
                "key": "user_message_body:user-1",
                "text": "تحقق من نوع\nنظام التشغيل الحالي",
            },
            {
                "key": "assistant_message_body:assistant-1",
                "text": "النظام الحالي هو Linux.",
            },
        ]
        self.assertEqual(
            workflow._extract_response(
                completed,
                "تحقق من نوع نظام التشغيل الحالي",
                {},
                {},
            ),
            (
                "user_message_body:user-1",
                "assistant_message_body:assistant-1",
                "النظام الحالي هو Linux.",
            ),
        )


if __name__ == "__main__":
    unittest.main()
