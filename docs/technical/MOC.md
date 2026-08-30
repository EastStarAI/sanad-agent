---
title: "خارطة المعمارية والرمز التقني"
description: "فهرس وخارطة وثائق المعمارية البرمجية، تصميم قواعد البيانات، وواجهات برمجة التطبيقات."
---

# Technical & Code Map of Contents (MOC)

This directory owns the technical specifications of "HOW" the system is structured (REST APIs, socket events, database structures, and third-party SDK blueprints).

> [!IMPORTANT]
> **Strict Separation Rule:**
> - **No Coding Contracts:** Coding rules and subdirectory constraints reside exclusively inside `<subproject>/AGENTS.md` files.
> - **No Action Commands:** Terminal execution and testing commands reside exclusively inside `.agent/skills/` files.
> - This folder must strictly contain static architectural specifications and system interfaces.

## Active Specifications

- **[Flutter VM Driver CLI Architecture](flutter_vm_driver_cli.md):** Driver-enabled Client instrumentation, standalone CLI boundary, deterministic selectors, and VM Service safety.
- **[Local Gateway and Sanad Home Protection](user_data_protection_and_minimization.md):** Authenticated desktop-only loopback transport, credential delivery, secure filesystem roots, legacy migration, and worktree isolation.
- **[Agent Interface and Runtime Architecture](agent_interface_runtime.md):** Gateway routing, active-run orchestration, recovery, and Sanad protocol translation.
- **[Client Portal Authentication](client_authentication.md):** Portal-owned login, polling-token secrecy, refresh, and local credential persistence.
- **[Desktop Authentication Exchange](desktop_authentication_exchange.md):** Credential-free live reconciliation between a native Flutter client and its local daemon through the shared auth document.
- **[Hosted Services Boundary](hosted_services_boundary.md):** Public/private ownership, supported local and cloud modes, and compatibility rules for EastStar AI hosted services.
- **[Client Local Daemon Control](client_local_daemon_control.md):** Source/standalone lifecycle ownership and worktree-aware endpoint resolution.
- **[Release and Update Architecture](update_architecture.md):** Shared release manifest, agent replacement ownership, first-install bootstrap, client self-update, and Appcast trust boundaries.
- **[Client Conversation Navigation Runtime](client_conversation_navigation.md):** Device-scoped sidebar projection, atomic history swaps, and deletion fallback.
- **[Client Conversation Cache Schema](client_conversation_cache_schema.md):** Device-scoped local cache, drafts, destinations, and recovery data.
- **[Device Runtime Settings Protocol](device_runtime_settings_protocol.md):** Client/daemon settings commands, ownership, validation, and synchronization.
- **[Web Search Runtime](web_search_runtime.md):** Daemon-owned providers, DuckDuckGo redirect normalization, fallback behavior, and SSRF filtering.
- **[Message Turn Replay Protocol](message_turn_replay_protocol.md):** Latest-turn identity, replay safety confirmation, authoritative idle boundary, history replacement, and route payload contract.
- **[Run Cancellation and Process Ownership](run_cancellation_and_process_ownership.md):** Run-scoped Stop, provider/tool interruption, process containment, bounded cleanup, and live/history terminal parity.
- **[Background Terminal Task Runtime](background_terminal_task_runtime.md):** Durable task ownership, atomic shell handoff, PTY supervision, cursor replay, typed wake admission, secure input, and lifecycle recovery.
- **[Remote Workspace Folder Mutation Protocol](workspace_folder_mutation_protocol.md):** Daemon-owned create, rename, and recursive-delete commands used by the remote workspace picker, including validation and failure semantics.
- **[Workspace Identity, Rename, and Change Path Protocol](workspace_identity_protocol.md):** Stable UUID identity, missing-folder projection, scoped Settings routing, display rename, and path repair.
- **Hosted data boundary:** The optional hosted service owns only the account, device-inventory, and usage data described in [Hosted Services Boundary](hosted_services_boundary.md); agent workspaces and conversations remain local.
- **[مواصفات قاعدة البيانات المحلية للوكيل | Local Agent Database Schema Spec](agent_database_schema.md):** تفاصيل وتصميم جداول قاعدة البيانات المحلية (SQLite - state.db) التابعة للوكيل sanad-agent لحفظ الجلسات وتفاصيل التعليق.
- **[بروتوكولات الاتصال ونظام نقل الأحداث | Communication Protocols & Event Flow Spec](communication_protocols.md):** توثيق شامل للاتصال الهجين وسوكت الأحداث، ومهام الانتظار والتوجيه والتعليق البرمجي.
- **[Context Compaction Architecture](context_compaction.md):** Durable goal-preserving compaction ownership, vocabulary, wire-safety rules, and prototype retirement boundary (Plan 53).
- **[معمارية تشغيل الوكيل المحلي | Local Agent Runtime & Prompt Assembly Spec](agent_runtime.md):** شرح معمارية تشغيل الوكيل المعتمد على لغة Dart، وترتيب موجه النظام والتحقق الأمني الذاتي.
- **[Experimental Realtime Voice](voice_streaming.md):** Current Gemini Realtime transport, audio, interruption, and capability boundaries.
- **[بروتوكول إعداد مزودي LLM والتخزين | Provider Protocol & Storage Spec](provider_protocol.md):** أوامر socket لإعداد المزودين، حالة المصادقة، التخزين المنفصل لـ OAuth tokens، وفصل configured عن runtime_ready.
- **[مواصفات نظام التصميم والمكونات المرئية للمشاريع | Design System & UI Spec](design_system.md):** توثيق شامل للألوان، الخطوط، الهيكل البنائي والواجهات التفاعلية المشتركة لمشاريع Sanad.
