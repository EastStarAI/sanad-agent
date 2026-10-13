---
title: "Task 77I4: Custom Chat image input and image-message edit/retry"
status: "pending"
current_gate: "G0 — authorized checkpoint and GitHub Actions verification"
remaining_estimate: "100%"
depends_on: "77I2 checkpoint; CI evidence"
---

# Goal

Repair image-message edit/retry behavior and close the custom OpenAI-compatible image-input gap inside the existing Plan 77 worktree. Keep main-based provider-name/custom-thinking work separate.

## Ownership and boundaries

Orchestrator owns checkpoint commits/pushes, GitHub checks, review and live tests. agy worker owns implementation and returned fixes after CI baseline verification; only one writer in this worktree. No merge, deployment, source switch, Home mutation or unapproved provider configuration/resource cleanup. Preserve tested Codex/Go/Anthropic wire behavior, canonical history, requester/session attachment grants, pruning, bounded media and privacy.

Custom image capability cannot be guessed from display/model name. Worker first studies Hermes and proposes minimal authority resolution for custom endpoints/models. Major schema/config/UI/architecture changes require explicit user approval before implementation. Coordinate any shared provider-instance changes with the separate main task; do not implement thinking controls here.

## Gates

### G0 — Checkpoint
- [ ] Review current public/private WIP, exclude secrets/env/bytecode/raw evidence and update task status.
- [ ] Authorized public checkpoint commit/push, then focused private Backend/gitlink checkpoint commit/push.
- [ ] Watch Public CI and private integration on exact checkpoint commits, triage failures before new code.

### G1 — Delegated diagnosis and proposal
- [ ] Read current contracts and Hermes image/custom-provider reference; report a concrete supported custom-route approach and approval questions.
- [ ] Diagnose actual edit/retry paths for messages with image attachments, local and hosted, retaining immutable original attachments until authoritative acceptance.
- [ ] Add red regressions for established failures, including failure/cancel preservation and no duplicate admission/re-execution.

### G2 — Implementation and independent review
- [ ] Implement bounded attachment edit/retry repairs; implement custom image support only after required design approval.
- [ ] Reuse existing canonical image codec; no raw path image URLs, blanket vision, retry from omission or source-history mutation.
- [ ] Worker analyzer/focused/E2E-as-needed tests pass with fixture-owned isolation; docs/contracts/graph updated.
- [ ] Reviewer independently reruns gates and returns defects until resolved.

### G3 — Interactive acceptance
- [ ] Reviewer verifies image attachment edit/retry on selected macOS/Web test Clients, with one-shot send ledgers and no retry after ambiguous outcomes.
- [ ] Exact custom model/provider sees pixels through an actually image-bearing request; text-only/unknown routes remain honest and safe.
- [ ] Regression smoke for already tested native protocols and draft cleanup remains green.
- [ ] Remaining estimate/gates and parent acceptance updated; no blanket claim of all-provider or whole-Plan success.

## Current evidence

User explicitly authorized checkpoint commit/push and CI observation before worker launch. Previous 77I2 Go live and normal fast suite succeeded; custom instances still fail closed. Provider catalog/thinking task is separately based on public main. This task has no new implementation or live acceptance yet.
