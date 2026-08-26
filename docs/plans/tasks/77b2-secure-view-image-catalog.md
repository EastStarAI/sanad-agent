---
title: "Task 77b2: Secure View Image Catalog"
status: "pending"
current_gate: "Waiting"
depends_on: "77b1"
file_budget: 10
evidence_id: "77b"
evidence_fingerprint: "sha256:649b8758bdef850c34646defccb7fa1e87a55791873bc7337d05502b564761ad"
---

# Task 77b2: أداة View Image والتسجيل الآمن

## Goal

إضافة `view_image` إلى workspace catalog وربطها بالـresolver والموافقة والـworker وإرجاع text+image result.

## Locked scope

- schema: `path` و`detail` فقط؛ local single file.
- authorize canonical target قبل stat/read؛ scoped approval باسم `view_image`.
- present with workspace regardless of adapter capability؛ provider projection مسؤولية 77c.

## Gates

### R0 — Evidence
- [ ] حل packet 77b وتأكيد fingerprint.

### B1 — Tool and authorization
- [ ] handler تستخدم `WorkspacePathResolver` ونفس external approval owner.
- [ ] internal/default/full-access/deny/symlink behaviors مثبتة.

### B2 — Catalog and result
- [ ] تسجيل workspace-only مع replay safety صريحة.
- [ ] نجاح الأداة ينتج summary آمنة ثم image block؛ الخطأ text-only closed code.

### B3 — Verification
- [ ] catalog/permission/handler tests وanalyzer ناجحة.
- [ ] لا تغيير في `file_read` أو `system_screenshot`.

## Acceptance criteria

- [ ] لا byte read قبل authorization.
- [ ] no-workspace يخفي الأداة وworkspace يظهر schema الصحيحة.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/capabilities/runtime_catalog_test.dart test/capabilities/view_image_handler_test.dart test/capabilities/permission_manager_test.dart 2>&1 | tail -5`
- [ ] تحديث العقود/QA والخطة وسجل parity.

