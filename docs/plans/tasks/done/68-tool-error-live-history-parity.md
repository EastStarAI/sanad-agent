# Task 68 — Tool Error Live/History Parity

## Goal
Persist the authoritative tool execution error flag with each tool-result history message so history hydration reproduces the same success/error state shown during live execution.

## Implementation
1. Carry `isError` through the tool execution callback that appends runner-owned history.
2. Recover the flag from typed checkpoint output records for resumed and batch execution.
3. Emit history `isError` from persisted metadata, retaining the legacy `Error:` prefix fallback for old rows.
4. Add protocol regression coverage for an error whose visible text does not begin with `Error:`.

## Definition of Done
- Live and hydrated tool events agree on error state.
- Sequential, parallel, deferred, direct, and resumed paths preserve the typed flag.
- Focused protocol/runtime tests and `fvm dart analyze` pass.
- Conversation event parity QA documents the invariant.
