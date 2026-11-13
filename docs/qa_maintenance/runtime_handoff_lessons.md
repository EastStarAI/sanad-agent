---
title: "Runtime Handoff and Resource Attribution Lessons"
description: "Operational lessons from migrating a managed development runtime between worktrees and from attributing daemon memory to the warm STT model."
---

# Runtime Handoff and Resource Attribution Lessons

Durable lessons from the task that produced
[docs/plans/tasks/167-stt-warm-model-mmap.md](../plans/tasks/167-stt-warm-model-mmap.md)
and Issue #426. Each entry records the symptom that misleads a reader, the
evidence that settles it, and the action that avoids repeating the mistake.

## L1 — Subtract the warm STT model before calling daemon memory growth a leak

**Symptom.** A daemon RSS reading jumps by roughly the size of a speech model
(833 MB for the 874 MB Egyptian-Arabic q8 entry) and looks like unbounded heap
growth across one session.

**Evidence that settles it.** The model is one anonymous `rw-p` block whose size
matches the ggml file, with `RssFile` unchanged. It appears when dictation runs
and disappears after `stt.model_idle_minutes` elapses. Subtract that block, then
compare: the remaining heap moved only tens of megabytes across the same period.

**Action.** Before attributing growth to retained conversation state, print the
large anonymous blocks from `/proc/<pid>/smaps` and identify any block near the
model file size. Report heap and model residency separately.

## L2 — `sanad-dev switch` cannot admit a handoff from a fresh worktree

**Symptom.** From a newly created worktree, `sanad-dev switch --runtime current`
aborts with `Switch aborted: no source agent matches current.` (or, with two live
agents and no `--port`, an ambiguity abort). No process is touched.

**Cause.** Switch admission discovers candidate agents by authenticating gateway
credentials from each candidate Home. A brand-new worktree carries no runtime
record and no Home linkage yet, so the discovery set is empty even though the
source daemon is running and reachable.

**Action.** Migrate a runtime with the supported launch path instead: `sanad-dev
stop` from the owning worktree, then `sanad-dev run --background --home
<absolute-home>` from the target worktree. The Home — identity, providers,
databases — is preserved; only the source root and the ports change. Record the
`status` output from the source worktree before and from the target worktree
after. The switch admission gap is tracked separately.

## L3 — A headless source client needs `DISPLAY` in the launcher environment

**Symptom.** `sanad-dev run` fails at `client readiness failed` while the journal
shows `Gtk-WARNING: cannot open display:` and `Built build/linux/arm64/debug/...`
immediately above it.

**Cause.** The client build succeeds, then the binary exits because the launcher
inherited an empty `DISPLAY`. The presence of a virtual framebuffer does not
help unless the variable points at it.

**Action.** Export `DISPLAY=:99` (or the live framebuffer's display) before
`sanad-dev run` in any agent-driven session, and confirm the framebuffer is
running first. Read the client journal — not only the agent journal — because the
platform failure lands there.
