---
title: "Compact Skill Load Output and Markdown Presentation"
status: done
---

# Compact Skill Load Output and Markdown Presentation

## Problem

`skill_load` accepts an `args` field that is only echoed, then returns pretty-printed JSON containing duplicated model input, frontmatter, provenance, and shadowing diagnostics. The client routes the tool through the generic JSON tile because its dedicated presentation is disabled.

## Goal

Make skill loading return only the selected skill source path and original Markdown content, and present that result like a normal File Read whose body is rendered Markdown.

## Implementation

- Remove `args` from the model-visible schema and the runtime/service call chain.
- Return a compact text result containing one source-path header followed by the original skill Markdown.
- Keep registry provenance, metadata, and shadowing information internal for inventory and resolution behavior.
- Route `skill_load` to a dedicated client tile using the File Read visual language.
- Show the selected `SKILL.md` path and render its content through the application Markdown renderer.
- Cover the compact runtime contract and the client running/error/completed Markdown states.
- Update capability and client-interface documentation.

## Definition of Done

- `skill_load` exposes only the required `skill` input.
- Successful output contains the selected path and Markdown body without redundant JSON fields.
- Skill-load events no longer use the generic input/output JSON presentation.
- Markdown headings, lists, emphasis, and code render through the shared Markdown boundary.
- Focused agent and client tests pass, and both analyzers pass.
- The completed plan is moved to `docs/plans/tasks/done/`.

## Verification

- Agent analyzer and focused runtime-catalog tests pass.
- Daemon-backed skill-load E2E passes sequentially.
- Client analyzer and focused skill-load widget tests pass.
