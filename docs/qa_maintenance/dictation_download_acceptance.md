---
title: Dictation Model Download Acceptance
description: "Live acceptance for a dictation model install: bounded memory, install truth across a sheet reopen, a device switch, a socket close, and an interrupted resume."
area: qa_maintenance
status: current
task: 158
---

# Dictation Model Download Acceptance

This runbook verifies the properties the automated suites cannot observe end to end:
heap stay, restart survival, and cross-device truth. The unit and widget coverage that
backs each step lives in `agent/test/stt/` and
`client/test/unit/dictation/dictation_install_truth_test.dart`.

## Prerequisites

- A matched runtime from the worktree under test:
  `sanad-dev run` (one Agent, one Client, one worktree-scoped Home).
- Two paired devices, the second one reachable and **without** the model installed, for
  the device-switch step. A single-device run may skip that step and say so.
- The largest catalog model is not already installed in the tested Home: delete
  `<home>/models/whisper/` (or the equivalent `stt.modelsDir` location) first, and
  confirm the sheet offers a download rather than **Use**.

Use `sanad-dev` for every runtime action. Never restart, stop, or sign in through a
bare `dart`/`flutter` command, and never point this run at the user's normal Home.

## 1. Bounded memory

1. Start the install of the largest model from the model sheet.
2. Sample the daemon's resident memory while it runs, at least five times:
   `ps -o rss= -p <agent pid>` (or Activity Monitor, filtered by `sanad_agent`).
3. **Pass:** the sampled value stays flat while the artifact grows, and never
   exceeds the artifact size by more than ~300 MB. A climb that tracks the download
   byte for byte is the `IOSink` regression returning: file the failure with the
   series, not with a single reading.
4. **Pass:** `sanad-dev logs agent -n 50` shows no per-chunk line and no repetition of
   the same install warning.

## 2. Install truth across a sheet reopen

1. Note the percentage while the install runs.
2. Close the model sheet, wait a few seconds, and reopen it.
3. **Pass:** the bar resumes at a higher percentage than step 1, in the same row, with
   a determinate bar and either a remaining-time estimate or a phase caption
   (`Verifying…`, `Finishing…`).
4. **Pass:** the row's only action is Cancel, and every other row's Download button is
   disabled for as long as the install runs.

## 3. Interrupted resume

1. Quit the Client (`sanad-dev stop client`) mid-download.
2. **Pass:** `sanad-dev status` still reports the agent running, and the partial
   artifact is still on disk (`ls` its `.partial` file).
3. Restart the Client with `sanad-dev run`, open the sheet, and finish the install.
4. **Pass:** the progress continues from the partial's offset instead of restarting at
   zero, the install completes, and the model becomes usable (a dictation run
   transcribes).

## 4. Device switch (A → B → A)

1. With the model installed on device A, select device B in the model sheet.
2. **Pass:** the sheet reflects B's own catalog (`Not installed` or `Ready`), not A's
   state relabelled.
3. Select A again and start dictation.
4. **Pass:** A is **Ready** and transcribes. A refusal that says the model is not
   installed on a device that has it is the transport-reuse regression: file it with
   the two device names and the sheet screenshot.

## 5. Second press and refusal

1. While an install runs, press Download on the same model again from a second Client
   connected to the same agent, or re-open and re-press as soon as the sheet allows it.
2. **Pass:** no second writer starts, the existing bar keeps its percentage, and the
   Agent log records a join for the same model (or an `install_in_progress` refusal for
   a different one). The socket must stay open in both cases: a closed socket cancels
   the install, which is the failure this step exists for.

## 6. Full volume

1. On a scratch volume holding less than the artifact plus ~256 MB, point `stt.modelsDir`
   at it and start the install.
2. **Pass:** the sheet refuses immediately with the localized "not enough free disk
   space" message, no request is made (the Agent log shows no download start), and
   nothing is left behind on the volume.

## Record

Keep the sampler series, the relevant `sanad-dev logs` excerpts (bounded to the past
few dozen lines), and the PR number in the task plan's outcome table. A skipped step is
recorded as skipped, with the reason; it is never recorded as passing.
