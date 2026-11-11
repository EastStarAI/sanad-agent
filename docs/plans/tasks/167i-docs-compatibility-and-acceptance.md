---
title: "Task 167i: Contract Docs, Compatibility Matrix, and Final Acceptance"
description: "توحيد الوثائق، مصفوفة توافق بين النسخ القديمة والجديدة، مصفوفة QA، وقبول نهائي مقابل معايير Issue."
status: "pending"
current_gate: "Ready for 167i-G1"
priority: "high"
depends_on: "167a, 167b, 167c, 167d, 167e, 167f, 167g, 167h"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 12
---

# Task 167i: Contract Docs, Compatibility Matrix, and Final Acceptance

## 1. Goal

The plan closes with one coherent documentation set, a compatibility matrix
proven by real runs, a QA matrix with pass/fail rows, and an acceptance report
against the linked Issue's criteria.

## 2. Scope

- Reconcile every touched contract: provider protocol, database schema,
  transcription runtime, cloud transcription, search runtime, settings hub,
  communication protocols.
- Fill the compatibility matrix: new client with old agent, old client with new
  agent, migrated database, and mixed capabilities on one instance.
- Fill the QA matrix with rows for: capability filter, curated vs custom
  capabilities, per-capability readiness and guard, batch transcription, streaming
  transcription per vendor, source selection, search routing and fallback.
- Record every deviation from the plan's decisions with its reason.
- Confirm the DoD of each task and the Issue acceptance criteria.

## 3. Invariants

- No documented behavior without a test or a recorded manual run behind it.
- No vendor-specific navigation detail in tracked docs; only behavior and
  contracts.
- No duplicated contract: each fact has one owning page and the others link.

## 4. Gates

### G1 — Documentation reconciliation

- [ ] Each touched contract page states the shipped behavior and links to its
      owner page instead of restating it.
- [ ] The reserved future capability appears only as prose, never as an
      enumerable value.
- [ ] `docs/llms.txt` lists any new page.

### G2 — Compatibility matrix

- [ ] Old client with new agent verified.
- [ ] New client with old agent verified.
- [ ] Migrated database verified with sessions, cache, and default intact.
- [ ] Mixed-capability instance verified end to end (one credential, two
      capabilities).

### G3 — QA matrix and acceptance

- [ ] Every row has a command, an automated test, or a recorded manual step with
      its evidence.
- [ ] Every Issue acceptance criterion maps to at least one passing row.
- [ ] Deviations are listed with owner-visible reasons.

## 5. Definition of Done

- Documentation builds/links verified; no stale statement contradicts shipped
  behavior.
- `fvm dart analyze` in `agent/` and `fvm flutter analyze` in `client/` clean at
  the final head.
- Acceptance report attached to the plan and the Issue.

## 6. Success test scenario

1. Run the compatibility matrix's four rows and record evidence.
2. Run the QA matrix; any failing row blocks acceptance.
3. Cross-check the Issue acceptance list against the matrix; assert no criterion
   is unverified.

## 7. Out of scope

New behavior; new providers; text-to-speech.
