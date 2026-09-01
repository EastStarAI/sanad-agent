---
title: "خارطة متطلبات المنتج والأعمال"
description: "فهرس وخارطة وثائق متطلبات المنتج، تجربة المستخدم، والأعمال الاستراتيجية للمشروع."
---

# Product & Business Map of Contents (MOC)

This directory owns the functional specifications of "WHAT" we are building and "WHY". 

> [!IMPORTANT]
> **Strict Separation Rule:**
> - **No Coding Contracts:** Coding rules and subdirectory constraints reside exclusively inside `<subproject>/AGENTS.md` files.
> - **No Action Commands:** Terminal execution and testing commands reside exclusively inside `.agent/skills/` files.
> - This folder must strictly contain product designs, wireframe specifications, and PRDs.

## Active Specifications
- [Sanad Agent Product Definition](prd_sanad_agent.md) — Current users, components, operating modes, stable capabilities, distribution, and experimental boundary.
- [Sanad Agent Features](features.md) — User-facing guide to local, remote, provider, workspace, tool, and interaction capabilities.
- [Sanad Agent Identity and Scope](project_identity_and_scope.md) — Independent public identity, open-source scope, and optional hosted-service boundary.
- [Provider Account Usage Limits](provider_account_usage_limits.md) — Instance-scoped usage windows, non-blocking freshness behavior, errors, and planned reset-credit controls.
- [Message Edit and Retry UX](message_edit_retry_ux.md) — Inline latest-root-turn editing, steer exclusion, navigation cancellation, replay warnings, and preserved original history.
- [Conversation Fork UX](conversation_fork_ux.md) — Fork from any durable final answer into an independent child session.
- [Conversation Navigation UX Spec](conversation_navigation_ux_spec.md) — Typed conversation destinations, Back/Forward behavior, atomic transitions, deletion fallback, and restart recovery.
- [Settings Hub](settings_hub.md) — Device-scoped settings, provider management, and runtime configuration experience.
- [Sanad Client Interface](client_interface.md) — Current devices, workspaces, conversations, providers, permissions, and responsive interaction behavior.
