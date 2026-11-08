---
title: "خارطة العمليات والأتمتة والنشر"
description: "فهرس وخارطة وثائق مسارات الأتمتة n8n، إعدادات الحاويات Docker، ومخططات النشر والتشغيل."
---

# Operations & Automation Map of Contents (MOC)

This directory owns the specifications of deployment structures, CI/CD pipelines, Docker runbooks, and n8n background workflow schemas.

> [!IMPORTANT]
> **Strict Separation Rule:**
> - **No Coding Contracts:** Coding rules and subdirectory constraints reside exclusively inside `<subproject>/AGENTS.md` files.
> - **No Action Commands:** Terminal execution and testing commands reside exclusively inside `.agent/skills/` files.
> - This folder must strictly contain static deployment runbooks, server orchestration layouts, and webhook mapping charts.

## Active Specifications
- [Developer Guide](developer_guide.md): Guide for repository setup, local development, tests, and CI/CD releases.
- [User Guide](user_guide.md): Guide for users installing and running the agent and client application.
- [Release, Signing, and Deployment Architecture](release_and_signing.md): Stable release channels, protected environments, signing ownership, secret inventory, atomic deployment, live-release gates, and the post-Production release announcement.
- [Community and Contribution Governance](community_governance.md): Routing, triage labels, pull-request protection, Discord structure, and public GitHub handoffs.
- [Public CI Pipeline and Merge Queue](continuous_integration.md): Job layout, test sharding, toolchain caching, the required-check aggregate, and the owner merge-queue runbook.
- [Brand Asset Generation and Platform Handoff](brand_asset_handoff.md): Approved canonical sources, reproducible icon generation, applied platform matrix, review exports, and live-surface handoffs.
- [Sanad Dev Worktree Runtime Plan](../plans/tasks/done/sanad-dev-worktree-runtime.md): Design for isolated daemon/client runs and interactive UI verification across concurrent Git worktrees.
