# Desktop Background Lifecycle and System Tray

This document specifies the background execution lifecycle and system tray integration for the Sanad Flutter Desktop Client on macOS and Windows (Plan 102c).

---

## 1. Overview

By default on desktop platforms, closing the main window in standard desktop applications terminates the process. For Sanad Client, background persistence is critical:
- The Client acts as an authenticated routing relay and host for local command-line tools (`sanad-client`), executing commands against remote connected agents.
- Sockets and push subscriptions (gateway connection, device presence, remote command relay) must remain operational even when the UI window is dismissed.

Under the background lifecycle model:
- Closing the window **hides** the UI rather than destroying the process or terminating connections.
- The system tray icon (macOS menu bar / Windows notification area) provides continuous status visibility and quick access to common actions.
- An explicit **Quit** action owned by the application lifecycle is the sole path for application termination.

---

## 2. Platform Scope and Support Boundaries

| Platform | System Tray Support | Background Close-to-Hide | Notes |
| :--- | :---: | :---: | :--- |
| **macOS** | Supported | Supported | `NSStatusItem` menu in top system bar; click opens menu or restores window. |
| **Windows** | Supported | Supported | `Shell_NotifyIcon` in taskbar tray; right-click context menu, left-click restores window. |
| **Linux** | Supported | Supported | `StatusNotifierItem` over D-Bus; the panel hosts the icon and opens the menu, so click events stay with the panel. On GNOME this requires the AppIndicator extension (Ubuntu ships and enables it). |
| **Web / Mobile** | N/A | N/A | Background lifecycle and system tray are native desktop only. |

---

## 3. Background Lifecycle Model

### 3.1 Window Close Interception (`WindowManagerService`)

On every desktop platform:
1. During application bootstrap, `WindowManagerService.initialize()` sets `setPreventClose(true)`.
2. When the user clicks the window close button:
   - The native platform event is intercepted by `WindowListener.onWindowClose()`.
   - `WindowManagerService` delegates to `DesktopLifecycleManager.handleWindowClose()`.
   - `DesktopLifecycleManager` invokes `hideWindow()`, which calls `windowManager.hide()`.
   - The Flutter process, event loop, sockets, `ClientCliHost`, and in-memory caches remain fully active.
3. During an explicit quit the manager already released `setPreventClose(false)` and destroys the window itself, so a close request that arrives while shutting down never hides the window again.

### 3.2 Restoring the Window (`Show`)

The main application window is restored and focused whenever:
- The user clicks "Show" in the system tray menu.
- The user left-clicks the tray icon.
- The user selects any conversation from the "Recent Conversations" submenu/list in the tray.
- Implementation: `DesktopLifecycleManager.showWindow()` invokes `windowManager.show()` followed by `windowManager.focus()`.

### 3.3 Explicit Shutdown (`Quit`)

"Quit" is the only path that performs full application shutdown. When triggered from the tray menu item "Quit":
1. **Tray Disposal**: Destroys the native tray icon and unhooks listeners (`AppTrayService.destroy()`).
2. **Client CLI Host Shutdown**: Unbinds the Unix domain socket / named pipe and stops the HTTP listener (`ClientCliHost.stop()`).
3. **Cache Flushing**: Synchronously flushes in-memory conversation drafts and snapshots to persistent storage (`ConversationCachePersistor.flush()`).
4. **Service Disposal**: Disposes `AppState`, `SanadSocketService`, and `DeviceConnectionCoordinator`.
5. **Window Teardown**: Disables `setPreventClose(false)` and destroys the native window (`windowManager.destroy()`).
6. **Process Exit**: Calls `exit(0)`.

Errors during any individual cleanup step are caught and logged; subsequent steps always proceed to ensure deterministic termination.

---

## 4. System Tray Projection and Actions

The system tray menu is constructed via `TrayMenuBuilder.buildMenu()` and updated reactively by `AppTrayService`.

### 4.1 Menu Layout

```text
Show
---
[Recent Conversation 1]
[Recent Conversation 2]
... (up to 5 conversations)
---
Agent: Running (or Stopped)
Restart Agent (or Start Agent)
---
Client CLI: Enabled (or Disabled)
---
Quit
```

### 4.2 Recent Conversations Projection

- **Source**: Aggregated from `ConversationCacheStore` across all cached devices.
- **Ordering**:
  1. `lastMessageAt` descending (nulls last).
  2. `updatedAt` descending.
  3. `id` ascending (stable tie-breaker).
- **Cap**: At most 5 conversations are displayed (never more than 5).
- **Formatting**: Titles longer than 35 characters are safely truncated with `...`. Empty or whitespace-only titles display as `New Chat`.
- **Safe Fallback**: If no conversations exist in cache, a disabled informational item labeled `No recent conversations` is shown.
- **Navigation Behavior**: Selecting a conversation brings the client window to the foreground via `showWindow()`, then navigates directly to `ConversationDestination.session(deviceId: ..., sessionId: ...)`. Only the selected conversation is activated; no other conversation state is mutated.

### 4.3 Local Agent Availability and Controls

- **Query**: Queried via `LocalDaemonController.isDaemonRunning()`.
- **State Projection**:
  - If running: displays disabled informational item `Agent: Running`, followed by clickable action `Restart Agent`.
  - If stopped: displays disabled informational item `Agent: Stopped`, followed by clickable action `Start Agent`.
- **Execution**:
  - Clicking `Restart Agent` calls `LocalDaemonController.restartDaemon()`.
  - Clicking `Start Agent` calls `LocalDaemonController.startDaemon()`.
  - Re-entrancy guard ensures actions are executed exactly once per click.
  - The menu status refreshes immediately upon completion.

### 4.4 Client CLI State and Toggle

- **State Projection**: Reflects `ClientCliCubit.state.enabled` (`Client CLI: Enabled` vs `Client CLI: Disabled`).
- **Toggle Action**: Clicking the item toggles the state via `ClientCliCubit.setEnabled(!enabled)`, which updates `SharedPreferences` and starts or stops `ClientCliHost`.
- **Reactive Refresh**: `AppTrayService` subscribes to `ClientCliCubit.stream` and updates the menu label dynamically.

---

## 5. Architectural Seams and Testability

All native platform plugins (`window_manager`, `tray_manager`) are wrapped behind abstract adapters:
- `DesktopWindowManagerAdapter`: encapsulates window show, hide, focus, preventClose, and destroy.
- `TrayManagerAdapter`: encapsulates tray initialization, context menu updates, and destruction.
- `TrayMenuBuilder`: pure function producing `TrayMenuItemDescriptor` lists, allowing 100% test coverage of menu layout, sorting, truncation, and callbacks without requiring native C++ or platform channel execution.

---

## 6. Dependency and Toolchain Compatibility

Tray support is macOS/Windows only, but the tray dependency is a normal
cross-platform Flutter plugin, so its Linux backend is compiled for every Linux
desktop build. `tray_manager` pulls in `nativeapi`, whose GTK/GIO backend calls
`G_APPLICATION_DEFAULT_FLAGS`, a name that only exists from GLib 2.74 onwards.

`client/linux/CMakeLists.txt` defines that symbol to the identical legacy flag
`G_APPLICATION_FLAGS_NONE` only when the local GLib predates 2.74, and only
before the generated plugin subdirectories are added. This keeps supported Linux
development toolchains (for example Ubuntu 22.04 with GLib 2.72) building the
Client with the Linux tray enabled.

### 6.1. Linux runtime surface

- The tray icon is a `StatusNotifierItem` published over the session D-Bus by
  `tray_manager`, so no `libappindicator` package is required at runtime; the
  panel (GNOME with the AppIndicator extension, KDE Plasma, and most others)
  hosts the icon and opens the menu itself, which means tray click events never
  reach the application on Linux. Every action must therefore exist as a menu
  entry, including `Show`.
- `client/linux/runner/my_application.cc` sets the GTK application display name
  to `Sanad`; without it the desktop shell labels the running window with the raw
  application id.
- Bootstrap initializes the tray service on every desktop platform, and a window
  close hides the window instead of exiting.
