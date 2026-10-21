---
id: 106
title: Context Compaction Resilience, Protocol Alignment, and Reference-Grounded Token Estimation
status: completed
gate: completed-with-106b-follow-up-pr
delivery: "[PR210](https://github.com/EastStarAI/sanad-agent/pull/210) and [PR229](https://github.com/EastStarAI/sanad-agent/pull/229)"
split_into: [116, 117, 118, 119, 120]
created: 2026-10-13
branch: fix/106b-remaining-compaction-and-thinking-stages
evidence_id: 106
evidence_fingerprint: sha256:521e2ac07cf2bec923e9ec68afab079e0b72aefbe883c8e6c28886c4cfee2374
amendment_evidence_id: 106-compaction-regression
amendment_evidence_fingerprint: sha256:8aa804e28d73531802382ed043c3a20bb699b254c10a1de044a04ed31b8638c1
---

# Task 106 — Compaction, Pressure and Provider Continuation

## Goal

Reliable manual/automatic/overflow compaction with preserved canonical history, tool/media relationships and user-selected thinking; honest provider-grounded measurements, useful safe feedback, a complete-request target and compatible same-session provider transitions.

## Completion — 2026-10-21

Task 106 is **complete**. It was delivered in two pull requests:

- [PR210](https://github.com/EastStarAI/sanad-agent/pull/210), squash `2607a3423c94f43553debb46c3866eea69ad878b`: wire outcomes, pressure, pairing/attribution, CLI compaction and the delivered baseline below.
- [PR229](https://github.com/EastStarAI/sanad-agent/pull/229), the 106b follow-up from `fix/106b-remaining-compaction-and-thinking-stages`: the scope in the next section.

The remaining queue was split into separately delivered tasks (see [Split of the Remaining Queue](#split-of-the-remaining-queue)). This file stays under `done/` for link stability.

### Delivered by PR229 (106b)

| Scope | What changed | Evidence |
|---|---|---|
| Stage1 F1 — pre-call attribution provenance | The claim transaction binds `last_pre_compaction_call` once, with genuine provider-instance identity (no template/alias collapse) and fail-closed `unknown/material_unverified` applicability. Completion, failure, restart and repeated claims cannot rewrite it. F2 (failed-operation scalars in `diagnostics_json` only) and F5 (`projection_still_over_budget`) are classified, not re-schematized. | `docs/technical/context_compaction.md` §11.3; `agent/test/evolution/compaction_boundary_repository_test.dart`, `agent/test/engine/runtime/compaction_coordinator_test.dart` |
| Stage1 F3 — dump pairing isolation | Normal dumps are keyed by request id; unknown/terminal ids fail closed; unkeyed auxiliary traffic never attaches to an in-flight keyed turn; retry attempts get distinct ids. | `docs/technical/context_compaction.md` §10.3; `agent/test/engine/llm_request_dumper_test.dart` |
| 0P — projection lockout after a partial history rewrite | A completed boundary with a missing source endpoint or retained-tail start is projection-ineligible with an invalidation diagnostic, and projection falls back to the next eligible boundary or full history instead of throwing `ModelProjectionException`. The boundary record is preserved for audit. Root-cause rewrite (0P-F1) and bounded recovery (0P-F2) moved to [Task 117](docs/plans/tasks/done/117-session-history-integrity.md). | `agent/lib/evolution/compaction/model_projection_builder.dart`, `agent/lib/evolution/models/compaction_operation_record.dart`; `agent/test/evolution/model_projection_builder_test.dart` (19 passed) |
| [Task 115](docs/plans/tasks/done/115-post-201-provider-thinking-route-admission-regression.md) — thinking admission | Carried and persisted selections are revalidated at admission; legacy provenance and default reset no longer resurrect a cleared preference; unknown routes are admitted with the provider default. | `agent/test/interfaces/runtime/carried_thinking_selection_admission_test.dart`, `agent/test/core/provider_thinking/thinking_route_session_sync_test.dart` |
| Five-layer thinking capability authority | Resolution order: user `config.yaml` `model_capabilities` → provider live `/models` metadata (OpenRouter, LM Studio, Kimi, Codex, Ollama) → shipped defaults `agent/model_capability_defaults.yaml` (generated into `generated_model_capability_defaults.dart` by `agent/tool/generate_model_capability_defaults.dart`, with a CI `--check`) → models.dev serving vendor → models.dev canonical model; otherwise unknown. Per-model name tables were removed. Adds the lower-only clamp, the `native_toggle_effort` wire and a single reactive HTTP 400 thinking-field recovery keyed by route + model + selection. | `agent/lib/core/AGENTS.md`, `docs/technical/provider_protocol.md` §2.3; `agent/test/core/provider_thinking/layered_thinking_authority_test.dart`, `agent/test/tool/generate_model_capability_defaults_test.dart` |
| Live round 1 repairs | L1: stopping a run waiting after a 429 no longer crashes the daemon (detached unwind contained at the stream boundary). L2: an inherited thinking selection no longer rejects the turn (agent and Client). | `agent/test/engine/agent_runner_test.dart`, `client/test/widget/route_thinking_mode_carried_selection_test.dart` |
| Live round 2 repairs | G1: `glm-5.2` on OpenCode Go follows its serving-vendor entry (no Off); 400 suppression is per selection. G2: opening a session in the Client no longer writes its thinking selection. G3: CLI `run` exits 1 on a rejected turn, logged at INFO. G4: CLI accepts `off`/`on` and names unexpected arguments. | `agent/test/cli/run_delegation_test.dart`, `client/test/widget/route_thinking_mode_real_preference_test.dart` |
| Live round 3 repairs (R4) | Always-selected thinking default: when the winning capability layer has options but no default, the default is filled from the next lower layer that declares one for the same model (`default_source` provenance); a route with no valid default shows a selected localized `Provider default` chip (no "Not selected"), sending no thinking field and writing nothing. Restart persistence: a conversation restored at Client startup as a placeholder adopts its own stored selection when its summary arrives, so a device-level last pick no longer overwrites it. | `agent/test/core/provider_thinking/thinking_pick_restart_persistence_test.dart`, `agent/test/core/provider_thinking/layered_thinking_authority_test.dart`, `client/test/widget/route_thinking_mode_selector_test.dart` |
| Live acceptance procedure | Daemon-backed CLI live acceptance reference. | `.agents/skills/sanad-agentic-developer/references/daemon-cli-live-acceptance.md` |

Verification at the accepted candidate: agent `fvm dart analyze` clean and `fvm dart test test/` +2850 ~14; Client `fvm flutter analyze` clean and `fvm flutter test` +1651; generator `--check` valid.

Test Home live acceptance (scalar receipts only; raw artifacts stay private):

| Round | Scope | Result | Budget used |
|---|---|---|---|
| r2 | Stage1/F3 fresh-session chain, thinking admission, capability display | Pre 24075 input → manual summary 12578/570 → first continuation confirmed 13715; 4/4 protected facts; operation row hash unchanged across restart and a second compaction. Moonshot `high`, Codex control `high`, Go deepseek-v4.1-flash `low` completed | 12 requests, 106982 input, 2 summaries |
| r3 | G1–G4 fixes | Go glm-5.2 menu High/Max without Off; glm-5.2 `high` and deepseek-v4-pro `off`/`high` completed with the expected directives; CLI `off` parses; glm-5.2 `none` → exit 1, zero provider calls, INFO log; opening sessions issued no `update_session_preferences` | 7 requests, 52778 input |
| r4 | Always-selected default and restart persistence | No empty or "Not selected" chip on any route; glm-5.2 shows Max by default and sent `reasoning_effort="max"` (HTTP 200, first live `max` on Go glm-5.2); an explicit High survived two agent restarts and a Client restore, with exactly one preference write | 5 requests, 16287 input |

Known gaps carried forward, not claimed as delivered:

- `qwen3.7-max` on OpenCode Go resolves to unknown (admitted with the provider default, no thinking field).
- `gpt-6-luna` and other Responses/Messages models on OpenCode Go still dispatch on Chat → [Task 120](docs/plans/tasks/120-opencode-go-per-model-protocol.md).
- The reactive 400 recovery with per-selection suppression is unit-proven; live evidence exists only for the earlier keying (r2).
- r4 observations: a new draft keeps a carried value the route also offers (High) rather than resetting to the route default (Max), which is an open product decision; the filled default shows no default-hint row for glm-5.2 on Go; the Client placeholder-restore path is proven by its outcome and unit tests, not observed directly.
- 0P live reproduction was `not_run` in r2/r3 for budget reasons → live gate moved to [Task 117](docs/plans/tasks/done/117-session-history-integrity.md).

<a id="split-of-the-remaining-queue"></a>

## Split of the Remaining Queue

The former ordered queue (0P follow-ups, Stage2, 3A, 3B, timeout toast, 116) is no longer routed through Task 106. Each item has its own task and pull request.

| Former item | New owner | Notes |
|---|---|---|
| 0P-F1 history rewrite re-ids rows; 0P-F2 unbounded recovery summarizer | [Task 117 — Session history integrity](docs/plans/tasks/done/117-session-history-integrity.md) | Before 118. |
| Stage2 near-window summarization resilience; Stage3A complete-request target, public metrics and replay-aware tail; Stage3B premature/repeated automatic pressure | [Task 118 — Compaction accuracy and target](docs/plans/tasks/118-compaction-accuracy-and-target.md) | Uses the locked decisions and observations below. |
| Misleading manual-compaction timeout toast | [Task 119 — Manual compaction timeout feedback](docs/plans/tasks/done/119-manual-compaction-timeout-feedback.md) | Delivered in [PR228](https://github.com/EastStarAI/sanad-agent/pull/228). |
| OpenCode Go per-model wire protocol (live round 1 D3) | [Task 120 — OpenCode Go per-model protocol](docs/plans/tasks/120-opencode-go-per-model-protocol.md) | After 116; keeps issuers stable. |
| Per-request destination-compatible projection | [Task 116](docs/plans/tasks/done/116-deepseek-reasoning-replay-across-tool-history.md) | Detached; own PR. |

## Delivered Baseline and Evidence

Preserve these behaviors; do not repeat completed work solely because older unchecked boxes once existed.

| Delivered scope | Evidence / limits |
|---|---|
| G1–G5: snake_case wire outcomes with legacy decoding, orphan-started reconciliation, model-facing pressure and consistent Client metrics | Original accepted implementation; historical grounding `106`. Regressions remain required, not new implementation tasks. |
| G6–G9: coherent structured-result pruning, complete auxiliary options/attachments/thinking, bounded nonfatal failures and localized toast/timeline/history explanations | Independent Wave A/B/C reviews under `temp/106-implementation/`; no silent thinking fallback or raw error exposure. |
| G10 daemon regression and G11 urgent pressure repair | Ten daemon cases exercise manual/auto/overflow, real-command post-claim failure, restart and sibling responsiveness; overflow retry refreshes the actual projection. Actual BaseOpenAI wire proof replaces rejected legacy/floor shortcuts; native review in `temp/106-implementation/g11-r4-native-review.md`. This does not close the later stage3B symptom. |
| Stage1 dump pairing and summary/first-post-call attribution | Checkpoints `0ead16c1` and subsequent R4 repairs, independently/automatically/live accepted before PR210. Failed attempts, trailing stream usage, dispatch-time first-call reservation and legacy-null provenance were reviewed; current pre-call extension is separate. |
| CLI peer-Client visibility, permission/execution-root scope and direct `session compact` | Independently reviewed and delivered in PR210. Per-turn grants do not become persistent/shared authority; the direct command targets one daemon session and never retries an ambiguous timeout or reports admission as completion. User verification of unchanged visibility/permissions stays `user_verified`. |

Key receipts, not a replay of every intermediate freeze:

- First pairing live session `fd8340bf…`: three ordinary requests and one summary; normal dumps unchanged, summary usage15162/854, first actual post-input19182. The7070 estimate mismatch required material attribution, not an invented cause.
- Later attribution live session `66c37765…`, operation `93c2a842…`: summary39398/739, first continuation19203 input/12928 cached, protected facts intact; exact dispatch identity persisted. Its then-unknown target outcome was honest, not full-target acceptance.
- Combined pre-merge freeze: Agent2907 passed/14 skipped, Client1644, focused300/63, daemon10/10; post-harness-repair Agent2911/14 skipped. Port-collision/home-bootstrap/fixture-secret findings were repaired, not hidden. Final pre-merge Public CI `39361520137` passed14/14 on `c7db115a`; that source was squash-merged as `2607a342`.
- Delegated Sanad live receipt: `oneshot-5d9175f4-e65c-4b94-ae29-5d48018950ea`; operation `c547a8fd…` completed once, paired dump, restart retrieval preserved it, and a later ungranted turn retained no `full_access`. The literal `default_mode` rewrite is unit-covered, not inferred from absent live metadata.
- Historical pressure audit: encoded image/opaque-state characters inflated estimates; provider-confirmed371839 input including370816 cache was incorrectly ineligible after restore. Wire/route/material proof and image-geometry repairs have regression evidence; neither those repairs nor a successful pre-PR201 compaction proves every later automatic trigger correct.

Full pre-condensation text and hashes are preserved in the private coordination run store. Intermediate failed/invalidated freezes remain historical evidence, never acceptance of the current candidate. No payloads or reasoning belong in this plan.

The measurement decisions and production observations below are retained as inputs for [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md).

## Locked Measurement and Target Decisions

### Minimal Durable Record

Reuse existing operation persistence, narrow additive JSON and the request dumper; no observability platform, generic event store, dashboard or broad schema redesign.

| Group | Required meaning |
|---|---|
| Identity/decision | Session/operation/request/step, actual provider/model, start/end/duration, trigger and safe stage/cause; window, internal budget, threshold, ratio/scope/denominator and prospective pressure/measurement kind. No invented started operation for pre-claim rejection. |
| Last ordinary pre-call | Exact historical call/time/input/cache plus current route/material applicability, immutable at claim; not mutable run totals. |
| Summary calls | Distinct request/pass/attempt, duration/outcome, supplied input/cache/output/reasoning, safe validation/fallback cause and opt-in paired-dump reference. Failed calls remain represented; aggregate cost is not one request's occupancy. |
| Candidate | Existing source/tail/boundary identities, continuity result and complete-request estimate; components only where measurable. |
| First actual post-call | Reserve the actual boundary-using request/step at dispatch; bind route/time/input/cache to that request. Missing first usage remains missing, never replace it with later growth; survive duplicates, out-of-order replies, retry, route change, repeated boundary and restart. |
| Result | Lifecycle completion is distinct from target met/not_met/unknown. Persist numeric evidence independently of optional payload capture and retain it after restart/temporary-dump removal. |

<a id="locked-provider-first-measurement-rule--2026-10-19"></a>

### Provider-First Measurement

- Exact, semantically understood provider input wins for that call; missing usage/components stay unknown, not zero or estimated-as-confirmed. Cache is part of input, not a context discount; avoid double counting inclusive components/reasoning/output.
- Bind measurements to actual route/model/request/step/time/material. Reuse a **proven unchanged wire prefix + estimated transmitted suffix** only; label mixed. A200000-token confirmed unchanged prefix stays200000; new assistant/tool/replay/user material belongs in the suffix, not a re-estimation of all history.
- Reusable component attribution requires matching scope/material/route. Prompt/schema/options/history/media/route/compaction drift invalidates affected reuse, not the historical receipt. Legacy/missing/incompatible proof fails closed to estimation; stale/out-of-order replies cannot replace unrelated newer facts. Restore through the actual producer→persisted receipt→fresh-runner wire-proof path, not a reconstruction compared with itself.
- No blanket words-to-token multiplier, unproven confirmed floor or fabricated capacity. Configured/advertised window, actual input and accumulated historical size are different measurements.

### Full-Request Target — Stage3A (Task 118)

- Target covers **summary + connected tail + system/runtime instructions + tools + media + required protocol replay**, not tail alone. Aim at the configured ratio (currently10%); user allows12–13% as this example's upper result, **percentage points**, not relative percent. Do not generalize `ratio +0.03` to all targets or add configuration silently.
- Full resolved window `W` is the public denominator, never internal usable input `U`. At `W=258000`,10% is25800,13% is33540 and nominal90% is232200. Public before/after/tail/occupancy/target/threshold share `W`; enforce internal protection without displaying usable-input/reserve or disguising early safety intervention as the nominal threshold.
- Generate the normal continuity-validated summary intact; measure required overhead and select the newest complete connected tail fitting the remainder. Reassemble/recheck at safe boundaries. Everything removed must be covered by summary source; bounded regeneration is allowed only for genuine coverage gaps, not an iterative shortening campaign. Never trim required summary sections, drop tools, lower thinking or shrink summary output limits to force fit.
- If fixed overhead/protected chains/mandatory summary exceed target, report measured unattainable/not-met safely; preserve canonical history and choices. Validate with the **first actual provider-confirmed total post-input**; pending usage is unconfirmed. Separately attribute later additions, non-comparable routes and reclaimed-fraction metrics. Successful continuation alone is not target success.
- Current runtime still uses tail-only target enforcement; the original complete-request goal remains unimplemented/unaccepted. Historical18.8% completion is not acceptance of that goal.

### Stage3A Follow-Up — Replay-Aware Tail Selection

Now owned by [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md) (Stage3A); not a blanket reasoning-removal feature. [Task 116](docs/plans/tasks/done/116-deepseek-reasoning-replay-across-tool-history.md) owns destination/issuer compatibility only if the shared projection boundary needs coordination.

- [ ] Trace selection cost versus actual transmitted projection at the owning boundary. Explain the paired tails: estimated20031/actual19689 versus estimated20666/actual32557, with fixed route/effort/instructions/tools. Separate the full-request target defect from the component-accounting defect; known actual opaque cost must not become zero or be estimated from ciphertext length.
- [ ] Add privacy-safe deterministic paired regressions using representative synthetic tool/replay shapes and explicitly fixture-scoped provider receipts:4 versus23 replay items,8 versus39 tool/result pairs. Cover actual cost reuse with proven identity and missing/stale/unmatched cost as unknown; do not import user Home payloads or fabricate live proof. The previous in-tolerance case must not hide the larger retained-chain case.
- [ ] Review the smallest design for full-request budgeting after intact summary/fixed overhead, then bounded reselection of safely connected history with source coverage. Prove old-turn cleanup separately from active-chain/handoff safety; no global replay deletion, changed effort, arbitrary tools removal or summary mutilation.
- [ ] Implement through the owning delegated lane only after its ordered gate; independent review, focused analyzer/tests and bounded same-route/same-effort live acceptance must validate the first actual post-input. Meet the10% goal with the already allowed upper13% result for this case, or honestly report measured infeasibility; never label17–20% as target success.

### Dumping, Failure and Media Boundaries

- Pair actual adapter request with response/error/timeout for every full/repair/chunk/reduce call using operation plus unique request identity. Preserve safe route/options, capture status/completeness and protected relative references. No cross-pairing, normal-turn `lastDumpFilePath` theft, unbounded mappings or successful-capture overwrite on cancellation.
- Numeric facts survive disabled/missing payload dumping. Raw bodies/reasoning stay private/opt-in under existing redaction, permissions and media bounds; no payloads/secrets/paths/stack traces in public diagnostics, logs, UI or task evidence. Missing diagnostics cannot kill the daemon, corrupt history or change policy.
- Failures preserve coherent structured results, canonical transcript, exact thinking/options and owner-valid lifecycle. Rejected/stale owners cannot finalize, clear newer busy state or drain its queue. Preserve snake_case and legacy decoding, safe localized feedback and orphan-started recovery.
- Client metrics retain `tail <= after`, consistent estimated/confirmed bases for reclaimed context and an accumulated-history label for historical totals above100%; reclaimed fraction is not window occupancy.
- Stored attachments/canonical history differ from active model projection. Budget transmitted media, never Base64 as ordinary text or all stored files. Compaction does not delete stored user attachments; textual summaries do not preserve all visual detail. Existing tool-image pruning is separate; no new media-retention policy is authorized.

## Post-Merge User Observation — 2026-10-20

- User requested read-only inspection of this normal-main conversation's latest two post-PR210 operations and requires90%/10% as product defaults. Primary `main` is2607a342; managed normal Home/source and one Client were discovered without mutation. Config and source defaults already use0.90/0.10 (`agent/lib/core/config.dart`); no80/20 default or settings edit is justified by this observation. Preserve/test the90/10 default in3A/3B.
- Auto `b9992c3d-11c6-4842-b9b5-ee8240bdeb54`: last ordinary confirmed214887/258000=83.29%; recorded prospective mixed235008=91.09%. Its threshold227592 is90% of usable252880, not nominal232200=90% of full window. This case exceeds both;83% alone does not prove an early trigger. Source confirms prospective admission; exact suffix/component attribution is still unreviewed.
- Earlier auto estimated post44905=17.405%, first confirmed33247=12.886%, tail20031. Previous manual `c9733d43-4b98-4fd0-b853-e97e50fcad9e`: estimated21223=8.226%, first confirmed32832=12.726%, tail18659. Both completed; paired summary captures exist with200 responses. These are correlated production observations, not acceptance of remaining fixes.
- Both decision snapshots retain `target_request_tokens=25288`, `target_scope=usable_budget`. Source checks tail against target and complete request only against usable maximum: this verifies the remaining3A scope defect. Opposite estimate-error directions forbid a universal correction multiplier.3B must distinguish prior displayed usage from next-request pressure and validate actual wire/material suffixes.
- Scalar extraction is preserved privately as `post-merge-two-compactions-20261020.json`; no raw content, credentials or history were imported into Test Home. Exact first post-call binding exists; immutable pre-call authority/suffix decomposition still needs its Stage1/3B gates. Do not treat summary input234862 as ordinary pre-call input214887.

### Third Observation — Confirmed18% After Compaction

- Same primary2607a342 runtime, read-only: auto `0572d8c2-f89e-4203-acb1-44501162e8cc` completed at19:31:23Z. First actual post step `91ffc3b0…` confirms46058/258000=17.852%, versus estimate45426=17.607%; only632 tokens/1.37% estimation error. This strengthens the known3A target-scope defect independently of gross estimation error: the estimate already exceeded target25288 while tail20666 passed. Estimated non-tail24760 is not a provider-confirmed component attribution.
- New exercised threshold case: last ordinary confirmed228256; prospective mixed231735=89.820% exceeds internal227592=88.214% of full window, but not nominal232200=90%. Unlike the earlier auto, this case lies between thresholds. It proves the implementation's denominator discrepancy mattered to its decision; the unsent ordinary request and estimated3479 suffix are not provider-confirmed.
- First post immutable `context_usage` and operation agree on46058/0 cached; mutable turn `usage` later reads56494 and is not this step's occupancy. Summary233450/3011 completed once with a200/stop capture; do not splice auxiliary usage into the ordinary chain. No new independent root cause or summary transport failure is established. Later provider comparison below assigns the12811 post-input increase to exact usage categories; implementation-level estimator attribution remains separate.
- Provider-attribution follow-up found the actual first-post ordinary dump by session UUID/time, correcting the coordinator's mistaken request-id-only lookup. Its response id matches database row29584951. Provider input46058 decomposes exactly into instructions8944, tool schemas2127, function-call/output items22226, all text messages including summary3137, and reasoning items/framing9624 (including2 input framing tokens on the new reasoning item). These are provider counts, not estimator-derived components. Do not call estimated tail20666 a confirmed tail cost or attribute its difference from total to summary/system alone; follow-up matches all23 encrypted reasoning items by hash to retained-tail providerState rows29584786–29584949. Thus actual tail is function-call/results22226 + replay9622 + retained text/framing709 =32557, not estimated20666. Five explicit text-message ids account for667; six empty idless assistants account for42; the unique remaining nonempty idless user summary maps to2428. Instructions8944 + tools2127 + summary2428 + tail32557 + new-reasoning input framing2 =46058. Aggregate-estimate accuracy does not establish component-estimate accuracy; carry the proven tail undercount into3A/3B. Private scalar receipt: `post-merge-third-compaction-provider-breakdown-20261020.json`.
- Consecutive-operation comparison verifies identical provider instance/model/high effort/config and credential revisions, plus byte-identical instructions/tools. Earlier post33247=12.886% was within this case's13% tolerance: instructions8944 + tools2127 + summary2485 + tail19689 + framing2. All4 replayed reasoning items hash-match earlier tail rows29584625–29584633. Latest tail32557 versus earlier19689 grew12868, while estimated tail grew only635 (20031→20666). Provider-attributed change is replayed reasoning+7710 (4→23 items), tool calls/results+4456 (8→39 pairs), retained text/framing+702, summary−57, fixed fields unchanged = total+12811. Different cached totals do not change full-input accounting. This is a paired3A/3B regression case, not proof that replay is unnecessary or safe to drop. Private receipt: `post-merge-compaction-provider-comparison-20261020.json`.
- Private operation receipt: `post-merge-third-compaction-20261020.json`. These observations neither accept nor invalidate the uncommitted106 candidate; keep3A/3B and applicability gates open. No normal Home content was imported or runtime/settings changed.

### Bounded Replay-Policy Grounding

- Evidence `106-replay-budget`, fingerprint `sha256:3b4ea85a649e2fec89a0d78f293498032b382c698e559660e0c24414c2bcca83`, is statically inspected, not executed/live accepted. Do not disable thinking or globally delete replay to meet occupancy. Distinguish obsolete prior-turn replay, active connected tool chains and native checkpoints; any task-restatement/re-anchoring during compaction requires integrated continuity/role-boundary proof, not isolated cleanup-helper coverage.
- All23 retained opaque items in the latest observed case belong to one original active run. Old-turn cleanup alone does not establish their safe removal; nor does source packet inspection guarantee the strict10% goal. Wire-compatible selection/full-request accounting and actual-provider cost attribution remain3A/3B obligations. Ciphertext character length and a zero local opaque estimate are not confirmed token cost. Preserve canonical history, user-selected effort and the configured full-request target; classify infeasibility honestly.

## Representative Data and Live Acceptance (Inherited by 117/118)

- Synthetic histories include large tool/rich-result/error/image chains, critical facts/pending asks and same/cross-route cases at unchanged window/threshold. Seed history, never expected outcomes or fabricated live usage/proof. Short fresh-session success is insufficient near-window acceptance.
- User authorized selecting needed recent **unscoped review/subagent** histories from the normal Home. Before export keep a private consistent snapshot/selection/hash/dependency manifest; source is read-only and includes committed WAL state. Ask before Codex-adapter sources or extending the corpus. Exclude the prohibited oversized reviewer corpus. Never resume `oneshot-660ca2ff-4504-4108-bb7b-212cb8fbc60b` or cancelled historical workers.
- Copy only necessary history/tool/media/boundary dependencies to idle isolated Test Home scenarios; no blind Home clone, credentials/identity/provider setup, unrelated sessions, jobs/queues/approvals/automation or executable pending work. Keep issuer-bound state genuine and protected; no issuer forgery. Imported usage is historical evidence, not fresh provider confirmation. Preserve source history and a pristine baseline; reset only verified disposable destination copies, never a live destination database or normal Home.
- Live work is executed by **Sanad**, with coordinator scope/monitoring/evidence acceptance. Use the verified Task106 Test Home daemon, CLI first and explicit session; keep its matched Client open. UI actions are for UI assertions or a proven CLI gap; no standalone substitute or CLI-as-UI proof. Fresh runtime ownership discovery precedes live requests/restarts; no autonomous source handoff.
- Large-context live route: `OpenCode Go / deepseek-v4.1-flash`; no local inference models. Other user-reported existing Test routes (`Moonshot`, `ChatGPT`, optional Anthropic-compatible `claude-haiku-4.5`) require exact saved identity/options/auth discovery, not assumed availability. No provider substitution, credentials copy or settings changes to hide failures.
- Bound calls/tokens/duration before expensive runs. The completed first-slice budget was three ordinary calls plus at most two summaries, aiming below180000 reported input; it is historical, not blanket authorization for later300k+ cases. Prefer deterministic faults over deliberate expensive upstream timeouts.
- Coverage distinguishes `fixture`, `daemon`, `live`, `blocked`, `not_run`: command/preflight/overflow producers, failed-summary shapes/attempts, low/no-benefit outcomes, rich/media continuity, route transitions, restart/concurrency and dumping privacy. Live overflow is claimed only if safely exercised; unavailable routes/quota are gaps, not passes.

## Reference and Evidence Navigation

- Behavioral design: [context compaction](docs/technical/context_compaction.md), [engine design](docs/agent_engine/context_compaction_design.md), [QA matrix](docs/qa_maintenance/context_compaction_qa.md). Original and amendment grounding IDs/fingerprints remain in frontmatter; source-specific comparisons/revisions stay ignored.
- Worker reports: `temp/106-implementation/` (Wave A/B/C/D, G11R4, current `precall-post-reboot-review.md`). Earlier local drivers are not a verified reusable harness; the unscoped `lsof` witness was withdrawn.
- Private orchestration artifacts:106-remaining run store, `post-reboot-intake` patch/hash manifest, `post-reboot-review` result/logs and `execution-run-reboot-20261020`; older106-g10-final artifacts are historical. Condensation backup is recorded under `coordination-condense-20261020`, outside tracked documentation.
- Live acceptance procedure: `.agents/skills/sanad-agentic-developer/references/daemon-cli-live-acceptance.md`, routed from `Sanad Agentic Developer` and `Sanad Client Tester`. Verify current CLI interfaces at use time; do not copy ports or PIDs from old receipts.
