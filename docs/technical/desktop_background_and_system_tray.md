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
| **Linux** | **Deferred** | Normal exit | Tray support is explicitly deferred. No unsupported tray is advertised; closing window terminates normally. |
| **Web / Mobile** | N/A | N/A | Background lifecycle and system tray are native desktop only. |

---

## 3. Background Lifecycle Model

### 3.1 Window Close Interception (`WindowManagerService`)

On macOS and Windows:
1. During application bootstrap, `WindowManagerService.initialize()` sets `setPreventClose(true)`.
2. When the user clicks the window close button (`X` on macOS / Windows):
   - The native platform event is intercepted by `WindowListener.onWindowClose()`.
   - `WindowManagerService` delegates to `DesktopLifecycleManager.handleWindowClose(isLinux: false)`.
   - `DesktopLifecycleManager` invokes `hideWindow()`, which calls `windowManager.hide()`.
   - The Flutter process, event loop, sockets, `ClientCliHost`, and in-memory caches remain fully active.
3. On Linux:
   - `setPreventClose(true)` is omitted.
   - If a close event occurs, `DesktopLifecycleManager.handleWindowClose(isLinux: true)` initiates an explicit quit.

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
