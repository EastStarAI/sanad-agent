# Windows Client TLS trust troubleshooting

Runbook for a Windows Client whose **Run local** install cannot verify the
release host's certificate chain. The refusal happens locally; the published
release is not the cause.

## Symptom

Pressing **Run local** fails before any download and the install log shows a
transport error such as:

```
The secure connection to the release server could not be verified on this
computer. Allow Sanad in your antivirus or network proxy, check that the system
clock is correct, or point SANAD_EXTRA_CA_BUNDLE at your network's root
certificate, then try again.
```

Clients older than the fix for Issue #434 print the raw verification error
instead:

```
Unable to fetch the release manifest: HandshakeException: Handshake error in
client (OS Error: CERTIFICATE_VERIFY_FAILED: unable to get local issuer
certificate)
```

## Why it happens on Windows

`dart:io`'s default `SecurityContext` takes trusted roots from the platform store
on macOS, iOS, and Android, but from the Mozilla list bundled into the Dart SDK on
Windows and Linux. A machine that inspects TLS replaces the chain with its own
root, so verification fails on Windows even though the same network works for
every other application:

- Antivirus or endpoint security HTTPS/SSL scanning (Kaspersky, ESET, Avast,
  Bitdefender, Sophos, eScan).
- A corporate, campus, or ISP proxy, or a zero-trust agent (Zscaler, Netskope,
  Fortinet).
- A partial or stale Windows root store, or a wrong system clock.

## Diagnose on the affected machine

Run in **PowerShell** (`$PSVersionTable.PSVersion` must print a version; `cmd.exe`
does not understand `irm`):

```powershell
# 1. Does the operating system itself reach the release manifest?
Invoke-WebRequest https://github.com/EastStarAI/sanad-agent/releases/latest/download/release-manifest.json -OutFile $env:TEMP\m.json

# 2. Is a TLS-interception root installed?
Get-ChildItem Cert:\LocalMachine\Root | Where-Object {
  $_.Subject -match 'Kaspersky|ESET|Avast|Bitdefender|Sophos|eScan|Netskope|Zscaler|Fortinet'
}

# 3. Is the clock sane?
Get-Date; w32tm /resync
```

Interpretation:

| Result | Meaning |
|---|---|
| Step 1 succeeds and the Client still fails | The OS trusts the chain but the Dart trust set does not: TLS interception is present. |
| Step 1 fails | Reachability or proxy problem, not only trust. Check the proxy configuration before continuing. |
| Step 2 lists an interception root | That authority must be trusted explicitly (see below). |
| Step 3 corrects the clock | Retry **Run local**; certificate validity windows depend on it. |

A phone hotspot separates the two remaining cases: a hotspot that works means the
network is intercepting; a hotspot that fails too means the machine intercepts.

## Remediate

1. **Exempt Sanad from HTTPS scanning** (preferred when the machine's owner
   controls the security software). Disable SSL/HTTPS inspection for the Client,
   or add an exclusion for it, then press **Run local** again.
2. **Trust the interception root explicitly.** Point the Client at the
   organization's root certificate — never at a leaf certificate:

   ```powershell
   # The bundle is additive: platform roots stay in effect and every
   # version, size, SHA-256, and platform-trust check still runs.
   setx SANAD_EXTRA_CA_BUNDLE "C:\ProgramData\sanad\corporate-root.pem"
   ```

   The variable is read when a release fetch starts, so the Client must be
   restarted afterwards. A bundle that is missing or malformed is logged and
   ignored; it cannot turn verification off.
3. **Install the Agent out of band** when the release fetch cannot be trusted at
   all. The Client then finds a stopped Agent already at its target version and
   registers the service without contacting the release manifest:

   ```powershell
   # Windows PowerShell or PowerShell 7
   irm https://sanad.eaststarai.com/install.ps1 | iex
   ```

   ```bat
   :: cmd.exe — `irm` is a PowerShell alias and is not recognized here
   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://sanad.eaststarai.com/install.ps1 | iex"
   ```

   Verify with `sanad --version` before retrying **Run local**.

## Verification

| Check | Expected |
|---|---|
| Interception root trusted and **Run local** pressed | Install completes; the version, size, SHA-256, and platform-trust steps still run. |
| No trust remediation applied | A localized cause-and-remedy message is shown and no artifact is written. |
| Install log | Contains no `HandshakeException`, no `CERTIFICATE_VERIFY_FAILED`, and no BoringSSL path. |
| `SANAD_EXTRA_CA_BUNDLE` pointing at a leaf certificate | Verification still fails closed; a leaf is not a trust anchor. |
| `SANAD_EXTRA_CA_BUNDLE` pointing at a missing or malformed file | The fetch behaves as if it were unset; the Client logs a bounded warning without the path. |

## Boundaries

- Verification is never disabled to make an install succeed. There is no
  `badCertificateCallback`, no pinning exemption, no plain-HTTP fallback, and no
  unverified download path. `SANAD_EXTRA_CA_BUNDLE` adds trust; it does not remove
  a check.
- A mirrored manifest host does not belong in this flow: a machine that cannot
  build a trusted chain to the release host cannot build one to our own host
  either.
- Never copy a private key or a leaf certificate into a bundle. Only the issuing
  root belongs there.

## Related

- [Release Verification Matrix](release_verification.md)
- [Update Architecture](../technical/update_architecture.md) — release transport trust and the platform trust stages.
- [User Guide — Windows installation](../operations/user_guide.md)
