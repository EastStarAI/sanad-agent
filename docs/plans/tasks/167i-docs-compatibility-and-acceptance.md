---
title: "Task 167i: Contract Docs, Compatibility Matrix, and Final Acceptance"
description: "Reconcile four-capability contracts and acceptance evidence, including Codex/OpenAI images without account-eligibility probes."
status: "pending"
current_gate: "Ready for 167i-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 12
---

# Task 167i: Contract Docs, Compatibility Matrix, and Final Acceptance

## 1. Goal

The plan closes with one coherent documentation set, a compatibility matrix
proven by real runs, a QA matrix with pass/fail rows, and an acceptance report
against the linked Issue's criteria and owner-approved image amendment.

## 2. Scope

- Reconcile every touched contract: provider protocol, database schema,
  transcription runtime, cloud transcription, search runtime, image runtime,
  conversation media, settings hub, communication/cancellation/fork contracts.
- Fill the compatibility matrix: new client with old agent, old client with new
  agent, migrated database, and mixed capabilities on one instance.
- Fill the QA matrix with rows for: capability filter, curated vs custom
  capabilities, per-capability readiness and guard, batch transcription, streaming
  transcription per vendor, source selection, search routing and fallback.
- Add image rows for both Codex OAuth and OpenAI API, automatic existing-account
  support, zero setup/eligibility probes, independent routing, honest options,
  non-idempotent recovery, durable originals, protected local/hosted media, fork/
  delete ownership, pruning/restart, and preview-vs-original download.
- Record every deviation from the plan's decisions with its reason.
- Confirm the DoD of each task and the Issue acceptance criteria, including the
  image amendment; do not silently rewrite external Issue history.

## 3. Invariants

- No documented behavior without a test or a recorded manual run behind it.
- No vendor-specific navigation detail in tracked docs; only behavior and
  contracts.
- No duplicated contract: each fact has one owning page and the others link.
- Fixture success is not live provider evidence. Maintainer integration validation
  is separate from user setup; any live generation needs authorization.
- No account-entitlement gate is introduced. Public-only mocks do not establish
  that a private hosted consumer shipped; mixed-version boundaries are explicit.

## 4. Gates

### G1 — Documentation reconciliation

- [ ] Each touched contract page states the shipped behavior and links to its
      owner page instead of restating it.
- [ ] The reserved future capability appears only as prose, never as an
      enumerable value.
- [ ] Image-input/vision and image generation are distinct; no stale statement
      requires every capability to pass an account probe or existing curated
      instances to remain permanently chat-only.
- [ ] `docs/llms.txt` lists any new shipped page, without presenting plans as code.

### G2 — Compatibility matrix

- [ ] Old client with new agent verified, retaining legacy chat and safe text
      results without unknown v1 block types.
- [ ] New client with old agent verified using actual old payloads, not a new
      compatibility field an old agent cannot emit.
- [ ] Migrated database verified with sessions, cache, credentials, UUID, and
      chat default intact.
- [ ] Mixed-capability instance verified end to end (one credential, two
      capabilities), including images independent of chat-model discovery.
- [ ] Existing Codex/OpenAI instances gain images automatically without reconnect,
      account check, or new default; explicit custom/settings state is preserved.
- [ ] Compatible local/hosted image routes enforce ownership/integrity; older
      routes produce actionable compatibility feedback with no binary fallback.

### G3 — QA matrix and acceptance

- [ ] Every row has a command, an automated test, or a recorded manual step with
      its evidence.
- [ ] Every Issue acceptance criterion and image-amendment decision maps to at
      least one passing row.
- [ ] Both image bindings have source-backed tests and recorded maintainer
      integration validation; routine setup/test/default actions issue zero
      generation/eligibility calls and claim no account-verified result.
- [ ] Recovery reuses completed references; uncertain dispatch never retries or
      fails over automatically. Originals survive pruning/restart and child
      ownership survives parent deletion; download saves original, not preview.
- [ ] Generated media has live/history parity, typed error/unknown-outcome states,
      en/ar coverage, bounded cache/navigation isolation, and authenticated scope.
- [ ] No secrets, binary data, private paths, or raw provider bodies leak through
      public metadata/logs; image request dumps redact prompts/payloads while
      authorized transient media caches remain bounded.
- [ ] Deviations and unresolved hosted-consumer boundaries have owner-visible
      reasons rather than unsupported completion claims.

## 5. Definition of Done

- Documentation builds/links verified; no stale statement contradicts shipped
  behavior.
- `fvm dart analyze` in `agent/` and `fvm flutter analyze` in `client/` clean at
  the final head.
- Acceptance report attached to the plan and, with delivery authorization, the
  Issue; fixture/runtime/authorized live evidence are distinguished.

## 6. Success test scenario

1. Run the compatibility matrix's rows and record evidence, including migrated
   Codex/OpenAI accounts and mixed-version generated-media delivery.
2. Run the QA matrix; any failing row blocks acceptance. Prove zero image setup
   probes, both generation bindings, original durability/download, and no replay.
3. Cross-check the Issue acceptance list and image decisions against the matrix;
   assert no criterion is unverified or reported complete without evidence.

## 7. Out of scope

New behavior; new providers; image editing; text-to-speech; account-entitlement
probes; and unapproved runtime handoff or publication.
