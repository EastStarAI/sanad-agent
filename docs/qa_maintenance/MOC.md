---
title: "خارطة الجودة والدعم والصيانة"
description: "فهرس وخارطة خطط الفحص وحالات الاختبار، أدلة حل المشكلات التقنية، ودعم التشغيل وصيانة المنصة."
---

# QA, Support & Maintenance Map of Contents (MOC)

This directory owns the specifications of test cases, manual validation flows, troubleshooting checklists, and technical runbooks.

> [!IMPORTANT]
> **Strict Separation Rule:**
> - **No Coding Contracts:** Coding rules and subdirectory constraints reside exclusively inside `<subproject>/AGENTS.md` files.
> - **No Action Commands:** Terminal execution and testing commands reside exclusively inside `.agent/skills/` files.
> - This folder must strictly contain static QA scenarios, verification steps, and system recovery runbooks.

## Active Specifications

- [Bundled Product Skills QA](bundled_product_skills_qa.md): Deterministic one-file embedding, SANAD_HOME install/update/remove, customization safety, fast startup, and release-artifact coverage.
- [Local Gateway and Sanad Home Security QA](local_gateway_and_sanad_home_security_qa.md): Authentication, Host/Origin rejection, secure writes, legacy migration, restart, Windows ACL, and worktree isolation coverage.
- [Memory Tool Reliability QA](memory_tool_reliability.md): Regression coverage for compact results, atomic batches, drift recovery, bounded retries, content safety, and frozen snapshots.
- [Runtime Source Switch QA](runtime_source_switch_qa.md): Regression coverage for requester-scoped pair selection, multi-runtime isolation, retained runtime identity, target conflicts, and full-pair rollback.
- [Release Verification Matrix](release_verification.md): Local and hosted evidence required for release identity, signing, installation, update, rollback, and supply-chain safety.
- [Community Governance QA](community_governance_qa.md): Static and live verification for labels, templates, skills, protected CI, Discord routing, and repository governance.
- [Conversation Cache Recovery QA](conversation_cache_recovery_qa.md): Local cache, draft, reconnect, and restart recovery coverage.
- [Mobile Session and Resume Recovery QA](mobile_session_resume_recovery_qa.md): Typed refresh outcomes, foreground resume, stale-cache continuity, and authoritative mobile conversation resynchronization.
- [Desktop Authentication Exchange QA](desktop_authentication_exchange_qa.md): Bidirectional login, refresh, logout, reconnect, and credential-free Local Gateway exchange coverage.
- [Device Name Editing QA](device_name_editing_qa.md): Device rename validation, synchronization, and failure coverage.
- [Provider Account Usage Limits QA](provider_account_usage_limits_qa.md): Regression coverage for instance isolation, capability discovery, freshness, stale responses, and usage-card presentation.
- [Message Edit and Retry QA](message_edit_retry_qa.md): Coverage for inline editing, idle-boundary ordering, side-effect confirmation, latest-turn identity, navigation cancellation, and current route selection.
- [Remote Workspace Folder Management QA](workspace_folder_management_qa.md): Coverage for folder create, rename, confirmed recursive delete, validation, request correlation, refresh, and remote-picker error behavior.
- [Remote MCP Management Boundary QA](remote_mcp_management_qa.md): Coverage for cloud-only configuration rejection, local configuration continuity, and preserved MCP tool use in cloud-origin turns.
- [Workspace Identity and Change Path QA](workspace_identity_relocation_qa.md): Coverage for UUID migration, missing folders, scoped Settings routing, display rename, path repair, and cache reconciliation.
- [Live Context Usage Indicator QA](live_context_usage_indicator_qa.md): Regression coverage for exact latest-provider values, cached-input visibility, tool-loop updates, session isolation, and history restoration.
- [Session Title Generation QA](session_title_generation_qa.md): Regression coverage for background first-exchange title generation, atomic placeholder ownership, stale-result rejection, and client synchronization.
- [Conversation Event Live/History Parity QA](conversation_event_parity_qa.md): Focused coverage for model-step segmentation, tool identity, opaque event IDs, and canonical history hydration.
- [Conversation Navigation Recovery Matrix](conversation_navigation_recovery_matrix.md): Recovery coverage for history, deep links, atomic loading, deletion fallback, stale responses, and restart restoration.
- [New Conversation, Composer, and App Bar QA](new_conversation_composer_app_bar_qa.md): Focused validation for Plan 32d composition, device-scoped draft recovery, canonical cleanup, responsive composer controls, and atomic App Bar presentation.
- [Device Workspace Sidebar QA](device_workspace_sidebar_qa.md): Focused validation for the Plan 32c device-scoped sidebar including cache-first rendering, pagination, live ordering, responsive drawer behavior, and accessibility expectations.
- [Plan 29 Provider Setup Regression Matrix](provider_setup_plan29_regression_matrix.md): Regression coverage for instance-first provider setup, model refresh races, default-instance onboarding, shared cache/recent behavior, and runtime-ready signaling.
- [Plan 30 Runtime Recovery Matrix](plan30_runtime_recovery_matrix.md): Focused coverage for runtime notice hydration, daemon-authoritative provider/model confirmation, multi-client recovery synchronization, and never-trapped-session flows.
- [Task 31 Authoritative Session State QA Matrix](task31_authoritative_session_state_matrix.md): Coverage for the seven durable execution states, per-session attention isolation, reconnect ordering, stop/run races, and visible route failover deduplication.
- [Task 36 Authoritative Steer, Queue, and Stop Recovery QA Matrix](task36_authoritative_steer_queue_stop_recovery_matrix.md): Coverage for daemon-owned delivery classification, raw request-id parity, pending-steer cancellation races, queue mutations, lossless Stop draft recovery, and first-writer restart claims.
