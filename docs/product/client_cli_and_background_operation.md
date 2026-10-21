---
title: "Client CLI and Background Operation"
description: "User-facing behavior of the Sanad Client CLI relay, its permission modes, and background desktop operation."
---

# Client CLI and Background Operation

This page describes what a Sanad Client user sees when command-line tools are
allowed to run Sanad commands on another connected device, and what happens when
the desktop window is closed.

---

## 1. What `sanad-client` Does

`sanad-client` is a remote-only command tool. It never runs commands on the
computer you are typing on; it asks the running Sanad Client to relay the request
to one of your other connected devices and streams the result back.

Local work on the same machine continues to use the local `sanad` command.

```text
sanad-client devices                                  # list your connected devices
sanad-client --device <device-id> ws list --json       # list that device's workspaces
sanad-client --device <device-id> run --workspace <id> --brief-file ./task.md
```

The tool resolves the running Client from the Sanad Home you are using:
`--home <path>` first, then the `SANAD_HOME` environment variable, then the
default Sanad Home.

---

## 2. Enabling It (Disabled by Default)

1. Open **Settings → Client CLI**.
2. Turn on **Enable Client CLI**.
3. Choose a permission mode:
   - **Default** — every command asks for your approval in the Client.
   - **Full access** — commands run without an extra Client prompt.
4. The Client CLI state is also visible and toggleable from the background tray.

Until this is enabled, any `sanad-client` call fails locally and nothing is sent
to any device.

---

## 3. Approval in Default Mode

In **Default** mode a command shows an approval overlay in the Client with the
target device and the requested command:

| Choice | Effect |
|---|---|
| Yes, allow this time | Runs this request only |
| Yes, allow for this session | Runs it and remembers the decision for that session |
| No, deny | Rejects the request; the caller receives a rejected result and no device is contacted |

Keyboard shortcuts `1`, `2`, `3`, and `Escape` resolve the overlay.

---

## 4. Multiple Homes and Multiple Clients

- A command reaches only the Client that owns the Sanad Home you asked for.
- One Home has exactly one live CLI owner; a second Client on the same Home
  cannot take over its endpoint.
- Disabling the feature, signing out, or quitting the Client releases the
  endpoint immediately.
- When the feature is enabled, the endpoint is restored automatically at the
  next start (and after signing in again).

---

## 5. Background Operation and the System Tray

On macOS and Windows, closing the main window hides it: the Client keeps its
connections, background work, and CLI endpoint available.

The tray menu offers:

```text
Show
Recent conversations (latest five)
Agent: Running / Stopped  →  Restart Agent / Start Agent
Client CLI: Enabled / Disabled  (toggle)
Quit
```

`Quit` is the only action that ends the application; it releases tray, CLI
endpoint, sockets, and cached state before exiting.

**Linux:** the same background behavior applies. The icon is a StatusNotifierItem
hosted by your desktop panel, so on GNOME you need the AppIndicator extension
(Ubuntu ships it enabled). The panel opens the menu itself, which is why every
action lives in the menu, including `Show`.

---

## 6. Boundaries

- Requests are forwarded as structured command arguments; they are never evaluated
  by a shell on the target device.
- File-backed input such as `--brief-file` is read locally and transported as
  request content, so the target device never reads your local path.
- Account credentials are never printed by `sanad-client` and never written into
  local runtime records.
