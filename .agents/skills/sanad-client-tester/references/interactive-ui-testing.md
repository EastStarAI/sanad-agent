# Interactive UI testing

Load this reference with `runtime-and-worktrees.md` for manual/custom control of a live driver-enabled Sanad Client. Do not load either file before a supported canonical conversation-runner invocation; load this file afterward only for selector, message-evidence, or return-navigation diagnosis.

The CLI is platform-neutral but is not an accessibility crawler for arbitrary Flutter apps. The target must run through `client/lib/driver_main.dart`, which registers Flutter Driver and Sanad service extensions. `sanad-dev ui` owns desktop/worktree discovery; mobile and web require a reachable explicit `--vm-url` or `VM_SERVICE_URL` and the same driver entry point.

## Workflow

1. Inspect the owning widget source and ensure each intended target has a unique descriptive `Key`.
2. Launch or identify the worktree-owned runtime according to `runtime-and-worktrees.md`.
3. Run `sanad-dev status`; in a linked worktree, require `worktree_runtime_badge` to show the current worktree directory.
4. Snapshot before every decision:

   ```bash
   sanad-dev ui snapshot --interactive --compact --json
   ```

5. Resolve one current keyed target, execute one action, and verify the post-transition state:

```bash
sanad-dev ui find --key chat_input --json
sanad-dev ui tap --key send_message_btn
sanad-dev ui tap --key dictation_mic_btn --hold-ms 800
sanad-dev ui hover --key row_archive --ms 800 --verify
sanad-dev ui enter-text --key chat_input --text "Hello Sanad"
sanad-dev ui scroll --key conversation_timeline_scroll --direction up --json
sanad-dev ui wait-for --key chat_input --timeout 10
sanad-dev ui ext --name ext.sanad_client.inspect_ui --args '{"onlyWithKeys":"true"}'
sanad-dev ui batch --file client/test/interactive/sample_recipe.json
```

`tap --hold-ms <ms>` (or `"hold_ms": <ms>` on a batch tap step) holds the same press for that long, which is how a long-press affordance is reached; 600 ms or more registers as a long press and the bound is 5000 ms. `hover --ms <ms>` (or `"hover_ms": <ms>` on a batch `hover` step) rests a synthetic pointer on the target for that long, which is how a hover-only affordance is reached; the dwell defaults to 2000 ms and the bound is 5000 ms, the pointer is always removed again, and the events stay inside the Client so the hover never takes focus or moves the real cursor. `ext` calls one `ext.sanad_client.*` extension on the discovered Client and prints its JSON result; names outside that prefix, including `ext.flutter.*`, are refused. A `tap` that reports `verification: obscured` was not dispatched — the result names the blocking key or widget above the target — so navigate back and re-snapshot instead of retrying.

6. Capture screenshots only when visual/layout evidence is needed:

   ```bash
   sanad-dev ui screenshot --out client/test/interactive/screenshots/my_screen.png
   ```

The standalone diagnostic entry point requires an explicit package configuration and VM URL:

```bash
fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart snapshot --vm-url <url>
```

## Stable selector and input rules

- If an expected target is missing, inspect the Flutter widget and add a unique key; hot reload, verify discovery, then continue. Do not guess coordinates.
- Workspace-scoped creation uses `sidebar_new_conversation_btn:<workspaceId>` after resolving one exact `workspace-group:<workspaceId>`.
- `enter-text` uses the Sanad text-entry extension and keeps the operating-system text channel active. Verify the same keyed field afterward; when physical typing behavior changed, include a human typing check before closing the live gate.
- Do not hardcode machine-specific dynamic selector paths. Discover or inject them.
- Do not cancel a driver action mid-flight. On a `Guarded function conflict`, use `sanad-dev restart client`, re-observe, and resume only from a safe phase.
- Prefer static scaffolds over Sliver descendants when a Sliver action can hang on macOS.
- Legacy Flutter Driver actions on screens with ongoing animations or streams belong inside `driver.runUnsynchronized`; do not globally enable mocked text entry around the Sanad extension.

## Conversation evidence

Treat conversation creation and send as irreversible one-shot phases. Verify `chat_input`, send once, and wait on response lifecycle events instead of polling snapshots or Jev.

Use event-scoped bodies when event ids are known:

```bash
sanad-dev ui find --key "user_message_body:<eventId>" --json
sanad-dev ui find --key "assistant_message_body:<eventId>" --json
```

Each lookup must return exactly one keyed rendered body. Multi-block assistant Markdown is consolidated in display order without footer metadata or duplicate descendants. Clipboard is diagnostic fallback only and is not acceptance evidence.

When navigation can race after completion, keep send, lifecycle waits, and a final `message_bodies` step in one batch/Driver connection. It returns the latest 50 event-scoped bodies with count and truncation metadata. Compare exact sentinels in code; use semantic judgment only for genuinely semantic acceptance.

For a reusable device/conversation/model/send/verify/return flow, load `jev-conversation-automation.md`.

## Pagination

Target `conversation_timeline_scroll`, not `chat_messages_list`. Keyed offset scrolls emit user intent and exercise pagination, follow opt-out, and saved-anchor persistence. Record returned offset/min/max, snapshot stable event ids after settling, and compare first/tail boundaries with a read-only database snapshot when required.

## Permanent tools

- `scripts/flutter_driver_cli.dart` and `scripts/flutter_driver_cli/` — canonical UI CLI and engine.
- `client/test/interactive/inspect_ui.dart` — legacy diagnostic crawler.
- `client/test/interactive/take_screenshot.dart` — legacy screenshot helper.
- `client/test/interactive/send_message_example.dart` — legacy interaction example.
