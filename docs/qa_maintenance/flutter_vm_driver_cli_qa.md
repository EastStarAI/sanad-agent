---
title: "Flutter VM Driver CLI QA Matrix"
description: "Static, managed-runtime, live interaction, and platform compatibility coverage for agent-driven Flutter control."
---

# Flutter VM Driver CLI QA Matrix

## Static and Unit Coverage

| Scenario | Expected result |
| --- | --- |
| CLI help without a running Client | Succeeds without VM discovery |
| `enter-text` with only a key and no text | Fails before connecting; the key value is never treated as input text |
| Missing batch recipe | Fails before connecting with a bounded error |
| Explicit VM endpoint | Is preserved exactly and does not trigger process-table discovery |
| Element query | Matches key, tooltip, type suffix, and free-text query deterministically |
| Analyzer and formatter | All changed Client and script sources pass |

## Managed Runtime Coverage

| Scenario | Expected result |
| --- | --- |
| Current worktree has no live driver client | `sanad-dev ui` fails closed and explains the driver prerequisite |
| Current worktree has a live driver client | Its recorded VM endpoint is forwarded to the standalone CLI |
| Explicit VM endpoint is supplied | The caller endpoint is preserved, including equals-style options |
| Windows host | FVM child execution uses shell resolution for the platform wrapper |
| Help request with no runtime | Help remains available |

## Live Interaction Coverage

| Scenario | Expected result |
| --- | --- |
| Snapshot | Returns keyed/textual elements and the current worktree badge |
| Tooltip-wrapped action | Actionable child contains the inherited tooltip |
| Selected semantic action | Keyed output reports semantic label, button role, and selected state without duplicate wrapper rows |
| Obscured text field | Snapshot omits its current value |
| Missing `--within` scope | Fails; it never broadens to the complete tree |
| Exact keyed tap | Scrolls into view, taps the requested element, and returns coordinates |
| Invalid tap index | Fails with match count; it never clamps to another element |
| Scroll until visible | Repeats through Flutter Driver until the target is visible or times out |
| Text entry during animation/streaming | Runs unsynchronized and remains responsive |
| Wait for presence/absence | Returns success only for the requested terminal condition |
| Screenshot | Produces a non-empty PNG outside tracked source artifacts |
| Batch JSON mode | Emits exactly one parseable JSON result and a nonzero status when any step fails |

## Platform Matrix

Desktop macOS is the required live PR gate because it addresses the accessibility gap. Windows and Linux require static/unit coverage plus a managed-runtime smoke test when runners are available. Android, iOS, and web are compatibility targets: verification requires the driver entry point and an explicitly reachable VM Service endpoint; no claim of arbitrary installed-app control is made.

## Residual Risk

Flutter Driver remains a development-only protocol and may vary across Flutter upgrades. Tests should pin selector behavior and VM connection semantics to the repository's FVM version. Production builds must not expose the driver service extensions.
