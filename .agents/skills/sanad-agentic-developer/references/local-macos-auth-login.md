# Local macOS Authentication with `sanad-dev ui`

Use this procedure when a developer asks an agent to complete a fresh interactive sign-in for a source-managed macOS Client. It controls the intended Client through its Dart VM and completes the browser-owned portion through `agent-browser`.

This is a fresh sign-in procedure only. Do not save, copy, restore, export, or document Client credentials, browser authentication state, authorization codes, or completed authorization URLs.

## Preconditions

1. Work from the workspace that owns the managed runtime.
2. Launch the macOS Client through the driver entry point. For a new runtime:

   ```bash
   sanad-dev run --background --driver -d macos
   ```

3. Read the managed inventory:

   ```bash
   sanad-dev status
   ```

4. Identify the intended macOS Client's VM Service URL. If more than one managed driver Client is running, pass that URL explicitly to every `sanad-dev ui` command. Never select the newest process or first global VM.
5. If the runtime uses a non-primary Sanad Home, set a shell placeholder to its absolute path and pass it explicitly to every command:

   ```bash
   sanad_home=<absolute-sanad-home>
   vm_url=<selected-macos-vm-service-url>
   ```

   Setting `SANAD_HOME` in the environment does not select that runtime for `sanad-dev` discovery or ownership checks.
6. Connect `agent-browser` to a user-approved automation browser session. Do not take over an unrelated personal browser window.

The examples below show `--home "$sanad_home"` because an explicit non-primary Home is the safest reusable form. When the selected runtime uses the primary Home, use the matching `--home user` selector instead.

## Inspect and navigate without coordinates

Confirm that the selected VM is driver-enabled:

```bash
sanad-dev ui snapshot --compact \
  --vm-url "$vm_url" \
  --home "$sanad_home"
```

Find the Profile destination after a restart or layout change:

```bash
sanad-dev ui find --query profile --compact \
  --vm-url "$vm_url" \
  --home "$sanad_home"
```

Tap the exact stable key returned by inspection, such as `sidebar_profile_destination` or `nav_tile_profile`:

```bash
sanad-dev ui tap --key <profile-destination-key> \
  --vm-url "$vm_url" \
  --home "$sanad_home"
```

Do not use mouse coordinates when a stable key or exact visible text exists.

## Optional fresh logout

Only sign out when the user requested a fresh cycle or explicitly authorized replacing the current authenticated state:

```bash
sanad-dev ui tap --text 'Sign out' \
  --vm-url "$vm_url" \
  --home "$sanad_home"
```

Verify the Client, not the action response:

```bash
sanad-dev ui snapshot --filter 'Cloud Login to connect' \
  --vm-url "$vm_url" \
  --home "$sanad_home"
```

A desktop Client may remain locally connected after Cloud logout. That is expected.

## Start and hand off the current attempt

Start one fresh attempt from the intended Client:

```bash
sanad-dev ui tap --text 'Sign in' \
  --vm-url "$vm_url" \
  --home "$sanad_home"
```

Immediately retrieve the active authorization URL from that exact Client, open it in the automation browser, and remove the shell value:

```bash
auth_url="$(sanad-dev ui auth-url \
  --vm-url "$vm_url" \
  --home "$sanad_home")"
agent-browser connect <approved-cdp-port>
agent-browser open "$auth_url"
unset auth_url
```

`auth-url` reads the in-memory challenge advertised by the selected driver VM. It does not inspect browser tabs, heap objects, another Client, or runtime files. Human mode writes only the ephemeral URL to stdout; use command substitution so it does not appear in the transcript.

The native Client may also open the system's default browser. Ignore that separate window. Continue only in the page opened explicitly by `agent-browser`.

## Complete the browser flow

Use the normal snapshot-and-ref loop:

```bash
agent-browser snapshot -i -c
```

1. Continue from the Sanad authorization page.
2. Select only the account authorized by the user.
3. Review and accept the provider consent page when it matches the requested sign-in.
4. If a password, passkey, second factor, recovery prompt, or unexpected account choice appears, stop and ask the user to take over. Never request or record the secret.
5. Re-snapshot after every navigation because element refs become stale.
6. Prefer semantic role locators when a ref is visible but a provider page ignores the click:

   ```bash
   agent-browser find role button click --name '<visible-button-name>'
   ```

7. Wait for the public completion page:

   ```bash
   agent-browser wait --text 'Authentication Complete'
   ```

Do not print the current page URL or include it in evidence.

## Verify the Client outcome

Poll for a bounded period and stop as soon as the terminal state appears. A simple follow-up inspection is usually enough:

```bash
sanad-dev ui snapshot --filter 'Cloud Connected' \
  --vm-url "$vm_url" \
  --home "$sanad_home"
```

For a desktop pair, verify `Local Connected, Cloud Connected`. If the worktree badge is expected, verify it in the same Client snapshot. Read only bounded logs when the UI does not reach a terminal state:

```bash
sanad-dev logs client -n 100 \
  --port <selected-vm-service-port> \
  --home "$sanad_home"
```

After completion, `sanad-dev ui auth-url` must fail because the in-memory challenge has been cleared. Do not retry the completed URL.

## Troubleshooting

- **No active authentication challenge:** inspect the intended Client, confirm it is signed out, and tap `Sign in` once. A completed, cancelled, or timed-out attempt cannot be reused.
- **No isolate exposes the extension:** the selected Client was not launched with `--driver`, or the VM URL belongs to another application. Restart the intended managed Client through the driver entry point.
- **Multiple managed Clients:** rerun `sanad-dev status`, choose the intended macOS VM, and pass `--vm-url` explicitly. Never let automation fall back to another Client.
- **Wrong page opened:** discard that tab, start a new attempt if necessary, and open only the value returned by `auth-url` for the selected VM. Do not infer the URL from the active browser tab.
- **Client timeout:** confirm whether the browser reached `Authentication Complete`, then inspect bounded Client logs. Start a new attempt only after the previous challenge is terminal.
- **Unexpected account or security prompt:** stop for user confirmation or takeover; do not guess, bypass, or capture secrets.

At the end, unset `auth_url`, `vm_url`, and `sanad_home` if they are no longer needed.
