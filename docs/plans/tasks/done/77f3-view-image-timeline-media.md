---
title: "Task 77f3: View Image Timeline Media"
status: "completed"
priority: "high"
depends_on: "77d3, 77e3"
current_gate: "done"
remaining_estimate: "0%"
tracked_file_budget: 15
evidence_id: "77e"
evidence_fingerprint: "sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a"
---

# Task 77f3: وسائط حدث View Image في Timeline

## Goal

إضافة projection آمنة لنتيجة `view_image` وعرض حدث بعنوان `View Image` وأسفله thumbnail قابلة للضغط محليًا وعن بُعد دون bytes أو paths في event/history payload.

## Locked scope

- event يحمل `media_id` opaque وsafe name وMIME والأبعاد والحالة فقط.
- title المرئي هو `View Image`؛ thumbnail أسفله وتفتح Lightbox.
- hydration كسولة قرب viewport، مع cancellation عند disposal/session switch.
- local fetch عبر Local Gateway المصادق؛ remote fetch عبر capability العامة المتوافقة.
- media identity مقيدة بالuser/device/session/purpose ولا تتحول إلى public URL.
- expiry/pruning يعرض `Image unavailable` ويحافظ على بقية tool row.

## Gates

### R0 — Media contract
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] تثبيت binary-free event/history schema وcapability behavior.

### G1 — Agent projection and retrieval
- [x] إنتاج media identity من canonical tool result دون نسخ غير محدودة.
- [x] إضافة authenticated local retrieval مع range/size/content headers الآمنة.
- [x] منع cross-session/device access وتسجيل bytes.

### G2 — Client rendering
- [x] إضافة View Image event renderer والthumbnail/unavailable states.
- [x] إضافة viewport hydration/cache bounds وLightbox accessibility.
- [x] توحيد live/history/reconnect projection.

### G3 — Tests
- [x] agent interface tests للمصادقة والعزل والexpiry.
- [x] Flutter widget/cache tests للتحميل والضغط والإلغاء والتاريخ.

## Acceptance criteria

- [x] الحدث يعرض `View Image` ثم الصورة، والضغط يفتحها كاملة.
- [x] event/history JSON لا يحتوي base64 أو absolute path أو reusable URL.
- [x] client غير مخول أو session خاطئة لا تستقبل byte واحدة.
- [x] pruning/expiry يحول الصورة إلى unavailable state دون كسر timeline.

## Definition of Done

- [x] analyzer للـAgent والـClient ناجح.
- [x] focused interface/widget tests ناجحة.
- [x] تحقق مرئي ظاهر محليًا؛ لا توجد remote fixture قبل بوابات hosted relay اللاحقة.
- [x] communication/design/QA docs محدثة أو روجعت وبقيت صحيحة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-09-15 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`.
- Resolved packet `77e` at fingerprint `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a` against clean public revision `c47038d` and private pin `6a52ad8e`.
- Locked a binary-free public schema containing only opaque `media_id`, safe name, verified MIME, positive dimensions, and closed availability. Bytes remain Agent-owned; paths, base64/data URIs, storage identities, credentials, and reusable URLs are forbidden.
- Locked exact user/device/session/media/purpose authorization before byte access, authenticated Local Gateway retrieval, later capability-gated hosted retrieval, and cancellable bounded Client hydration with stable unavailable degradation.
- Evidence run: `refrence_projects/.sanad-evidence/runs/77f3-reference-grounding-2026-09-15.md`.
- Remaining estimate: `75%` for 77f3 and approximately `19%` for Plan 77.
- Next gate: `G1 — Agent projection and retrieval`.

### 2026-09-15 — G1 complete

- Status transition: `in_progress/G1` → `in_progress/G2`.
- Added deterministic opaque media identity derived from session/tool-call/block identity. Live and hydrated tool-result projections expose only safe metadata; retrieval resolves the already-durable typed tool result and creates no second stored image copy.
- Added authenticated `GET /media/view-image/<media_id>` on the loopback Gateway with exact `device_id + session_id + media_id` admission, single-range support, bounded content length, verified MIME, `nosniff`, and private/no-store caching. Wrong device is forbidden and wrong session returns no bytes.
- Focused analyzer clean; port-binding Local Gateway suite passed 22/22 with `--concurrency=1`, including binary-free projection, partial content, authentication, and cross-scope denial.
- Remaining estimate: `50%` for 77f3 and approximately `18%` for Plan 77.
- Next gate: `G2 — Client rendering`.

### 2026-09-15 — G2 complete

- Status transition: `in_progress/G2` → `in_progress/G3`.
- Unified live and hydrated `view_image` metadata through the canonical mapper and a strict typed media validator. Reconnect reconciliation retains the same merged tool identity and metadata.
- Added a repository-owned authenticated Local Gateway fetch path with exact hardware/session/media scope, 12 MiB response ceiling, coalesced in-flight requests, last-listener cancellation, and a 12-entry/24 MiB in-memory LRU.
- Added stable loading/unavailable/decode-failure states, bounded thumbnail, and an accessible zoomable Lightbox with an explicit close affordance. Presentation receives a loader abstraction and never reads credentials or HTTP transport directly.
- Focused Client analyzer clean; focused mapper/repository/widget suite passed 14/14. Approved exceptional task budget is exactly 15/15 tracked files.
- Remaining estimate: `25%` for 77f3 and approximately `17%` for Plan 77.
- Next gate: `G3 — Tests`.

### 2026-09-16 — G3 complete / task closed

- Status transition: `in_progress/G3` → `completed/done`.
- Agent and Client analyzers passed. Changed-path Agent suites passed: authenticated Local Gateway media retrieval `22/22` with `--concurrency=1`, plus Sanad translator/history bridge regression `43/43`. Client focused mapper/repository/widget suite passed `14/14`; full Client fast suite passed `1,159/1,159`.
- Security coverage includes binary-free public JSON, missing authentication, wrong device/session, invalid range, expired/pruned bytes, strict MIME/size validation, scoped request construction, bounded LRU eviction, cancellation on disposal, live/history parity, thumbnail activation, and accessible Lightbox closure.
- Visible isolated macOS Client build ran successfully from this worktree, then was stopped. No remote fixture exists before the later hosted-relay gates, so no remote visual claim is made here.
- `graphify update .` rebuilt `24,059 nodes / 33,140 edges / 849 communities`; final tracked-file budget is `15/15`. Reference parity and verification are recorded in the required `77f3` evidence run.
- Baseline exception: the unrelated monolithic Agent `test/interfaces/interfaces_test.dart` fails from its fourth pre-existing case with `No element`, then cascades into timeouts/mock/FK failures when run both inside the full suite and alone. This task does not claim a clean full Agent suite; focused changed-path suites and analyzers are green.
- Remaining estimate: `0%` for 77f3 and approximately `16%` for Plan 77.
- Next dependency task: `77f2 — Attachment Transfer UX` at `R0`.
