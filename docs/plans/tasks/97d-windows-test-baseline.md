---
title: "97d: موثوقية اختبارات أدوات التشغيل"
status: completed
current_gate: G2
remaining_estimate: "0% (independently reviewed, corrected, and verified on Windows; ready for gate delivery)"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
---

# 97d — موثوقية اختبارات أدوات التشغيل

## Goal

إصلاح fixtures والتوقيت والتنظيف على Windows دون إضعاف سلوك المنتج.

## Locked scope and ownership

- جميع بنود G1–G4 من سجل cross-platform-test-baseline المتقاعد ضمن النطاق، بما فيها foreign shim/install --force وartifact fingerprint/executable/locked reuse؛ لا يكتفى بعناوينها المختصرة هنا.
- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/plans/done/sanad-dev-cross-platform-test-baseline-reliability.md`، `docs/qa_maintenance/test_suite_performance_qa.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [x] تصنيف كل فشل: منتج، fixture، startup، timeout، تنازع أو تسرب مورد؛ تصنيف unit/filesystem/OS/exclusive.
- [x] إصلاح المسارات والملكية وUnicode/spaces/drive/UNC ضمن دعم المنتج؛ لا تعديل production لدعم fixture خاطئة.
- [x] إثبات إغلاق journals وخروج العمليات وتحرير المنافذ دون sleeps ثابتة؛ التتابع فقط للموارد الحصرية.
- [x] قياس wrappers/artifact reuse/AOT background args؛ تجهيز فحوصات المنصات الأخرى دون اشتراط تشغيلها قبل إغلاق Windows.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [x] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [x] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تشغيل تحديث Graphify بعد تعديل الكود.
- [x] تحديث current_gate وremaining_estimate عند إغلاق البوابة مع دليل؛ تحديث حالة الأب يملكه دمج فرع التجميع، والتحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [x] مجموعة sanad-dev كاملة خضراء على Windows مرتين دون تجاهل حالات Windows المدعومة.
- [x] لا عملية أو منفذ أو journal lock أو lease مؤقت متسرب، ولا زيادة عامة للمهل.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] التفويض الحالي يجيز commit/push مستقلين للبوابة 97d فقط؛ لا merge ولا protected labels ولا runtime source switch.

## Evidence

### Independent review findings and corrections

The initial handoff was not accepted as written. Review found and corrected four substantive issues before gate acceptance:

1. Windows raw-path fixtures were over-escaped, so the claimed UNC and NT-device-prefix cases did not use real Windows syntax. They now use actual drive, UNC, and `\\?\` / `\\?\UNC\` forms.
2. The locked-artifact test created an unlocked file and asserted deletion. It now holds an exclusive Windows file lock, proves setup succeeds while cleanup cannot delete the active file, then releases the handle in `finally`.
3. The foreign-shim test pointed back to the same checkout. It now creates a functional wrapper for a distinct checkout and proves `setup` preserves its exact content; collision rejection and explicit `install --force` remain separate assertions.
4. PowerShell wrapper fixtures persisted temporary test directories into the real user PATH. Both Windows fixture copies now suppress only `Ensure-UserBinPath` in the copied script. The leaked `%TEMP%\sanad-*` PATH entries were removed once, and an exact before/after PATH hash check passed across both final full-suite runs.

The only production correction retained is the real ownership/path-identity defect: non-existent Windows paths previously fell back to case-sensitive string equality. `lib/src/infrastructure/path_equivalence.dart` now centralizes lexical comparison, correct device-prefix handling, host case/separator semantics, and symlink fallback. `runtime_context.dart` and ownership state consume that boundary; test-only public exposure through the composition root was removed.

### Windows host and test classification

- OS: Windows 11 Pro 64-bit, build 26200.
- SDK: Flutter 3.47.0 / Dart 3.13.0 via FVM.
- Pure/path tests: `test/support/sanad_dev_path_fixture_test.dart` (10).
- Windows wrapper/OS integration tests: `test/cli/sanad_dev_windows_bootstrap_test.dart` (8).
- The added tests bind no ports, contain no fixed sleeps, and do not request suite-wide sequential execution or timeout increases.
- Wrapper children use `Process.run`; strict recursive teardown must succeed. The final runs left no `sanad-win-bootstrap-*` or `sanad-bootstrap-fixture-*` directories, which also proves no child or locked handle retained those fixture roots.

### Separated timing evidence

All measurements are from this review worktree on the host above:

| Surface | Tests | Dart reporter case time | Invocation wall time | Result |
|---|---:|---:|---:|---|
| Pre-existing suite only | 163 passed, 17 skipped | 2 s | 9,811 ms | pass |
| New 97d tests only | 18 passed | 6 s | 12,370 ms | pass |
| Full suite run 1 | 181 passed, 17 skipped | 6 s | 13,848 ms | pass |
| Full suite run 2 | 181 passed, 17 skipped | 6 s | 13,332 ms | pass |

FVM/SDK startup was measured separately with five `fvm dart --version` invocations: `5035, 5042, 5160, 5015, 5072 ms`; median `5,042 ms`. Wall times therefore are not presented as test-case times. The new integration cost is dominated by eight real PowerShell wrapper cases; the ten path/fixture cases complete below the reporter's one-second resolution.

### Exact verification

Run from `scripts/sanad_dev/`:

- `fvm dart format --output=none --set-exit-if-changed ...` — pass after formatting, 0 pending changes.
- `fvm dart analyze` — pass, no issues.
- `fvm dart test test/support/sanad_dev_path_fixture_test.dart` — 10 passed in `<1 s` case time.
- `fvm dart test test/cli/sanad_dev_windows_bootstrap_test.dart` — 8 passed in `6 s` case time.
- `fvm dart test test/runtime/ownership/sanad_dev_ownership_assessment_test.dart test/discovery/sanad_dev_process_selection_test.dart test/runtime/lifecycle/sanad_dev_doctor_stop_test.dart` — 24 passed.
- Pre-existing files only (all `*_test.dart` except the two added files) — 163 passed, 17 skipped.
- `fvm dart test` twice consecutively — both passed with 181 passed, 17 skipped.
- User PATH before/after hashes across the two final full runs were identical.
- `graphify update .` was invoked as required; the installed Graphify version generated only local `.graphify/` working data rather than the repository-contract `graphify-out/` location, so generated data was removed from the delivery diff.

### Remaining platform ownership

97d closes the Windows gate only. Hosted macOS/Linux parity, expected-count lane enforcement, and final managed-runtime/UI acceptance remain owned by 97k/97l. No Client, Agent runtime, aggregation worktree, or runtime source was changed by this gate.
