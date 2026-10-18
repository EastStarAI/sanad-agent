---
title: "Task 77b2: Secure View Image Catalog"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
depends_on: "77b1"
file_budget: 10
evidence_id: "77b"
evidence_fingerprint: "sha256:649b8758bdef850c34646defccb7fa1e87a55791873bc7337d05502b564761ad"
---

# Task 77b2: أداة View Image والتسجيل الآمن

## Goal

إضافة `view_image` إلى catalog عند وجود Workspace أو attachment scope معتمدة، وربطها بالـresolver/grant والموافقة والـworker وإرجاع text+image result.

## Locked scope

- schema: `path` و`detail` فقط؛ local single file.
- authorize canonical target قبل stat/read؛ scoped approval باسم `view_image`.
- present with workspace أو admitted session attachment regardless of adapter capability؛ provider projection مسؤولية 77c.

## Gates

### R0 — Evidence
- [x] حل packet 77b وتأكيد fingerprint.

### B1 — Tool and authorization
- [x] handler تستخدم `WorkspacePathResolver` ونفس external approval owner.
- [x] internal/default/full-access/deny/symlink behaviors مثبتة.

### B2 — Catalog and result
- [x] تسجيل source-scoped مع replay safety صريحة: workspace أو session attachment grant.
- [x] نجاح الأداة ينتج summary آمنة ثم image block؛ الخطأ text-only closed code.

### B3 — Verification
- [x] catalog/permission/handler tests وanalyzer ناجحة.
- [x] لا تغيير في `file_read` أو `system_screenshot`.

## Acceptance criteria

- [x] لا byte read قبل authorization.
- [x] no-workspace/no-attachment يخفي الأداة؛ workspace أو admitted attachment يظهر schema الصحيحة مع scope المناسبة.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities/runtime_catalog_test.dart test/capabilities/view_image_handler_test.dart test/capabilities/permission_manager_test.dart 2>&1 | tail -5`
- [x] تحديث العقود/QA والخطة وسجل parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/B1`.
- Resolver: evidence ID `77b` returned `ready`; fingerprint matched `sha256:649b8758bdef850c34646defccb7fa1e87a55791873bc7337d05502b564761ad`.
- Mandatory source revisions, licenses, path-confinement/image-result implementations, and safety tests were inspected and recorded in the ignored run record.
- Adopted boundaries: canonical target authority, exact attachment grants, approval before byte read, safe text+image ordering, and text-only closed failures.
- Rejected boundaries: URL/data/batch input, extension trust, arbitrary read-only external access, and provider-gated catalog registration.
- Remaining estimate: `75%`.
- Next gate: `B1 — Tool and authorization`.

### 2026-09-14 — B1 complete

- Status transition: `B1` → `B2`.
- Resolution: handler canonicalizes through `WorkspacePathResolver`; relative workspace paths execute internally while symlink escapes are classified by their canonical target.
- Authority: exact admitted attachment paths bypass workspace approval only for that file; all other external workspace targets use the existing `PermissionManager` owner and canonical `external_workspace_path::view_image::<target>` key.
- Read ordering: default denial and attachment-scope denial return before stat or byte-reader invocation; full access bypasses the prompt through the existing workspace policy.
- Focused evidence: internal/default/full-access/deny/symlink and no-byte-before-authorization behavior passed.
- Remaining estimate: `45%`.
- Next gate: `B2 — Catalog and result`.

### 2026-09-14 — B2 complete

- Status transition: `B2` → `B3`.
- Catalog: `view_image` is absent without a source scope, workspace-scoped when a workspace exists, and exact-attachment-scoped without one; registration is independent of provider capability.
- Contract: schema accepts one required `path` plus optional `detail=low|auto|high|original` with `auto` default; execution explicitly opts into restart replay safety.
- Result: success emits a private-path-free dimensions/MIME/detail summary followed by one truthful image block; validation, permission, read, and worker errors emit text only with a closed code.
- Attachment paths enter through a daemon-owned session-scope resolver and never enter generic turn metadata.
- Remaining estimate: `20%`.
- Next gate: `B3 — Verification`.

### 2026-09-14 — B3 and task complete

- Status transition: `B3` → `complete`; Plan 77 advances to `77c1/R0`.
- Verification: analyzer clean; 30 catalog/handler/permission tests passed; Graphify rebuilt.
- Security evidence: authorization-before-byte-read is injected-reader tested; exact attachment scope rejects sibling files; URL/data/directory inputs and closed worker failures remain text-only.
- Regression boundary: `file_read` and `system_screenshot` production files are unchanged.
- Documentation: capability contract, technical design, QA ownership, task, and plan updated; evidence parity has no deviations.
- File budget: 9 tracked paths, below the limit of 10.
- Remaining estimate: `0%`.
- Next task: `77c1 — Rich Provider Codecs`.

