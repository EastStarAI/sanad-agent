---
title: "خارطة محرك ومنطق الوكلاء"
description: "فهرس وخارطة وثائق منطق وهندسة الوكلاء، سجل الأوامر النظامية، ومواصفات أدوات الذكاء الاصطناعي."
---

# AI & Agent Engine Map of Contents (MOC)

This directory owns the specifications of the agent reasoning loop, prompt engineering blueprints, function calling specifications, and tool capability descriptions.

> [!IMPORTANT]
> **Strict Separation Rule:**
> - **No Coding Contracts:** Coding rules and subdirectory constraints reside exclusively inside `<subproject>/AGENTS.md` files.
> - **No Action Commands:** Terminal execution and testing commands reside exclusively inside `.agent/skills/` files.
> - This folder must strictly contain prompt registries, tool capabilities description, and agent logical specifications.

## Active Specifications
- [Capability Runtime Architecture](capability_runtime.md): Tool specifications, per-turn catalogs, permissions, MCP, workspace/web services, skills, and platform tools.
- [Context Compaction Engine Design](context_compaction_design.md): Goal-preserving pressure measurement, tail selection, summarization, and continuity validation (Plan 53c).
- [LLM Adapter Runtime Contract](llm_adapter_runtime_contract.md): يفصل النص النهائي وreasoning القابل للعرض وحالة المزود opaque، ويحدد خيارات الطلب والاستمرارية.
- [Codex Responses Runtime Design](codex_responses_runtime_design.md): عقد codec والبث والاستكمال المحدود والتعافي من replay state المرفوض.
