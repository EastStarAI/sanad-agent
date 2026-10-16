---
title: "Desktop Background Lifecycle and System Tray QA"
description: "Gate-linked pass/fail coverage for close-to-hide background operation, tray projection, and platform scope."
---

# Desktop Background Lifecycle and System Tray QA

Owning plan: `docs/plans/102-client-cli-remote-relay-and-desktop-tray.md`
Owning task: `docs/plans/tasks/102c-desktop-background-system-tray.md`
Technical spec: `docs/technical/desktop_background_and_system_tray.md`

---

## G0 — Platform and lifecycle contract

| Area | Pass | Fail |
|---|---|---|
| Platform scope | Tray integration is initialized on macOS, Windows, and Linux desktop; web and mobile never advertise a tray | Tray initialized or advertised on web/mobile |
| Linux behavior | Closing the window hides it, a real `StatusNotifierItem` is registered on the session bus, and the panel menu carries every action including `Show` | Linux exits on window close, advertises no item, or registers an icon with no menu |
| Dependency compatibility | Linux desktop build succeeds on the supported toolchain baseline (GLib < 2.74 included) | Deferred tray dependency breaks the Linux build |
| Web compilation boundary | The Client Web build compiles without the native tray/FFI library: only `tray_manager_backend_native.dart` imports `package:tray_manager`, and the Web artifact carries the no-op unsupported adapter | Web build fails on `cnativeapi`/`ffi` (`Only JS interop members may be 'external'`), a shared library imports `package:tray_manager`, or a runtime `kIsWeb` check substitutes for the compile-time boundary |
| Explicit quit ownership | Only `Quit` destroys the app: tray, CLI endpoint, cache flush, state disposal, window destroy | Window close disposes sockets, CLI endpoint, or application state |

Automated owners:
- `client/test/unit/infrastructure/platform/desktop_lifecycle_manager_test.dart`
- `client/test/unit/infrastructure/platform/tray_manager_backend_test.dart`
- `client/linux/CMakeLists.txt` GLib compatibility shim (verified by `fvm flutter build linux --debug`)
- Real Web compilation (verified by `fvm flutter build web --debug --target lib/driver_main.dart`)

---

## G1 — Background lifecycle

| Area | Pass | Fail |
|---|---|---|
| Close-to-hide | `handleWindowClose(isLinux: false)` hides the window and keeps sockets, caches, and the CLI endpoint alive | Process exits, or state/sockets are disposed on close |
| Restore | `showWindow()` shows and focuses the existing window | A second window is created or focus is lost |
| Re-entrancy | Repeated close/show/quit requests stay deterministic; `quit()` runs its cleanup once | Duplicate cleanup, double exit, or a half-disposed app |
| Quit cleanup | Each cleanup step is attempted even when an earlier step throws | One failing step aborts the remaining teardown |

Automated owner:
- `client/test/unit/infrastructure/platform/desktop_lifecycle_manager_test.dart`

---

## G2 — Tray projection and actions

| Area | Pass | Fail |
|---|---|---|
| Menu layout | Show, up to five conversations, Agent state, Start/Restart Agent, Client CLI state, Quit | Missing action, or a conversation list longer than five |
| Conversation ordering | `lastMessageAt` desc, then `updatedAt` desc, then `id` asc; empty titles rendered as `New Chat`; long titles truncated | Unstable ordering, duplicate rows, or crash on a missing title |
| Selection navigation | Selected conversation opens the client window and navigates only to that destination | Other conversation state mutated implicitly |
| Agent availability | Unavailable → `Start Agent`; available → `Restart Agent`; each invokes the existing controller once | Both actions shown, duplicate invocation, or no status refresh |
| Client CLI state | Label reflects the settings owner and toggling reuses `setEnabled` | Tray keeps its own enablement state or drifts from Settings |
| Refresh cost | Menu refresh is debounced and skips identical menus | Refresh loop under constant repaint |

Automated owners:
- `client/test/unit/infrastructure/platform/tray_menu_builder_test.dart`
- `client/test/unit/infrastructure/platform/tray_manager_service_test.dart`

---

## Linux evidence (verified 2026-10-15)

| Check | Evidence |
|---|---|
| Tray icon registered | Client log: `NativeTrayManagerAdapter: System tray icon initialized` |
| Session-bus item | `RegisteredStatusNotifierItems` lists `org.kde.StatusNotifierItem-<client pid>-1` |
| Menu published | `com.canonical.dbusmenu.GetLayout` returns 10 entries: `Show`, five recent conversations, `Agent: Running`, `Restart Agent`, `Client CLI: Enabled`, `Quit` |
| Menu ownership | The item exposes the client-pid-based bus name and a `Menu` object path, so the panel menu belongs to the running Client |
| Close-to-hide | `Desktop window close intercepted` + `Hiding desktop window to background` on every window close, with the process, sockets, Agent link, and CLI endpoint still active in the background |
| Show | `Restoring desktop window from background` after selecting `Show`, with the previous session state intact |
| Quit | `Explicit quit initiated: executing deterministic shutdown`, followed by gateway/local socket disconnect, CLI runtime-record release, tray item unregistration, and process exit while the Agents kept running |

## Manual platform verification (macOS / Windows)

Still required on real macOS/Windows hardware before the tray release is declared
complete:

| Step | Expected |
|---|---|
| Close the window with the tray icon visible | Client keeps running; tray icon remains; sockets and the CLI endpoint stay available |
| `sanad-client devices` while the window is hidden | Same result as with the window visible |
| Tray → Show, and tray icon click | Window restored and focused |
| Tray → recent conversation | Window foregrounded on that conversation only |
| Tray → `Start Agent` / `Restart Agent` | Existing controller action runs once; menu status refreshes |
| Tray → `Client CLI` | Toggles the same setting as Settings → Client CLI |
| Tray → Quit | Tray removed, CLI ownership released, cache flushed, process exits |
| Linux control | Window close hides the window, the tray item and CLI endpoint stay alive, and `Quit` ends the process |

---

## Verification commands

```bash
cd client && fvm flutter analyze 2>&1 | tail -5
cd client && fvm flutter test test/unit/infrastructure/platform/ 2>&1 | tail -5
cd client && fvm flutter build web --debug --target lib/driver_main.dart 2>&1 | tail -5
cd client && fvm flutter build linux --debug 2>&1 | tail -5
```
