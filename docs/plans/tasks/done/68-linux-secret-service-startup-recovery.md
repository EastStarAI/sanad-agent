# Task 68 — Linux Product Vault and Platform Verification

## Supersession notice

This completed task records the Linux credential contract that existed before
Task 81. The active implementation and release candidate now support automatic
owner-protected file credentials plus durable user/system systemd and OpenRC
services on Headless Linux; see
`docs/plans/tasks/81-linux-headless-one-command-install-and-durable-service.md`.

## Historical problem

At the start of Task 68, the Linux Agent invoked `secret-tool` directly. A normal
Linux system could provide a working desktop Secret Service while omitting that
executable, and a headless/server installation could provide neither D-Bus nor
Secret Service.
Missing vault infrastructure previously allowed authentication reload—especially
`pending_agent_logout` reconciliation—to abort daemon bootstrap and trigger the
supervisor repeatedly.

Phase 1 normalized vault launch failures and kept daemon startup fail-closed.
At Task 68 completion, Gate L2 covered only the Linux desktop path and deliberately
left unattended Headless cloud credentials for later work. Task 81 has now
superseded that limitation with the owner-protected file backend and durable
service lifecycle.

## Historical goals

1. A normal Linux desktop user installs and uses Sanad without manually running
   `apt` or installing `secret-tool`, GNOME Keyring, D-Bus, or another dependency.
2. Task 68 kept a Headless Linux Agent without Secret Service crash-free and
   fail-closed while deferring unattended cloud capability; Task 81 later
   superseded this historical boundary.
3. Daemon startup and local health remain available when the selected credential
   backend is unavailable; only cloud authorization fails closed.
4. Secure backends never fall through silently to plaintext or another
   lower-precedence source.
5. A server with no supported trust root may use an explicitly selected,
   prominently warned plaintext compatibility mode so the product remains usable.
   This is an operator-owned security exception, never the default or an implied
   secure-storage mode.
6. Complete and verify Linux before beginning any Windows implementation work.

## Evidence Gate R0

External reference grounding is complete under evidence packet fingerprint
`sha256:6b31fc859d80d4cfef9e63d78805e3bf971dcce515f06a18dbe72d9aff471286`.
The adopted source-neutral patterns are typed secret references, bounded
non-interactive resolution, owner-scoped degraded state, explicit recovery, and
late secret materialization. Plain owner-only JSON/SQLite storage and ciphertext
stored beside an unprotected wrapping key are rejected as secure backends.

## Accepted Linux Design

### 1. Backend selection

Linux desktop and headless installations use distinct capability-aware backends:

- **Desktop:** use Linux Secret Service without requiring the external
  `secret-tool` executable. Official package metadata or installer behavior owns
  every required runtime dependency.
- **Headless with a hardware/platform trust root:** use a non-interactive backend
  that survives reboot and protects the Agent P-256 identity and Device
  Credential independently from ordinary Sanad state. TPM/vTPM-backed identity
  and service-manager credential delivery require a focused prototype before
  becoming the official backend.
- **Headless with an operator-owned source:** support a bounded credential
  reference/provider suitable for orchestrator-mounted credentials or an
  external secret manager. It must not expose arbitrary secret reads to Agent
  tools or require a paid provider as a product dependency.
- **Explicit plaintext compatibility mode:** available only when the operator
  knowingly accepts the risk after secure capability detection finds no selected
  backend. It is not described as a vault or secure storage.

Backend identity and selection are durable non-secret metadata. Once a secure
backend is selected, temporary unavailability must not authorize fallback to
plaintext or a different source.

### 2. Explicit plaintext compatibility mode

Plaintext mode is an intentional exception to the secure default and obeys all
of these constraints:

- disabled by default and never selected implicitly;
- interactive setup presents the security consequences and requires an explicit
  affirmative choice separate from ordinary installation confirmation;
- non-interactive setup requires a dedicated, unambiguous opt-in flag; absence
  of that flag fails cloud credential setup rather than enabling plaintext;
- upgrades preserve an existing explicit selection but never migrate a secure or
  unconfigured installation into plaintext automatically;
- secrets remain outside repositories/workspaces, receive the narrowest
  available owner-only filesystem permissions, and never enter arguments, URLs,
  logs, diagnostics, release metadata, or normal configuration output;
- status/doctor surfaces a persistent warning and a supported migration path to
  a secure backend;
- cloud use is permitted because the operator accepted the risk, while malformed,
  missing, unreadable, or unverifiable credential material still fails closed;
- removal and migration delete plaintext only after the replacement backend
  passes write/read verification; failed migration preserves recoverable bytes
  and reports the continuing risk.

### 3. Runtime failure and recovery

- `AuthManager.initialize()` preserves daemon and Local Gateway startup when a
  credential backend is unavailable.
- In-memory Device Credentials, pending credentials, and signing authority are
  cleared unless loaded from the selected backend successfully.
- Pending logout and legacy migration state remain retryable until verified.
- Cloud identity publishes a typed, credential-free unavailable state with an
  actionable recovery path; it does not create a restart loop.
- Explicit login, pairing, logout, migration, and credential mutation remain
  strict and never claim success after a failed backend operation.
- Recovery can reload the selected backend without reinstalling the product.

### 4. Installation, update, and removal

- Source execution uses the same backend selection and failure semantics as the
  compiled Agent.
- The official Linux Client package declares every desktop runtime dependency
  that package metadata can manage. The portable bundle and standalone Agent
  installer perform capability preflight and provide product-owned setup rather
  than terminal instructions to install dependencies.
- Clean install, reinstall, and upgrade preserve the selected backend and
  credential identity. Failed executable replacement retains the existing
  rollback behavior.
- Uninstall removes service/application files according to the existing data
  retention policy and never silently leaves a plaintext credential while
  claiming all sensitive data was removed.
- Migration from Phase 1 and older plaintext formats deletes legacy bytes only
  after verified replacement storage.

## Linux Implementation Gates

### Gate L1 — Reproduction and product contract

- Reproduce source startup with Secret Service present but `secret-tool` absent.
- Reproduce headless startup with no session D-Bus or Secret Service.
- Record packaging, installer, upgrade, and removal gaps.
- Update this task before product code. **Complete.**

### Gate L2 — Desktop Secret Service

- Remove the runtime dependency on the external `secret-tool` executable.
- Prove write/read/delete and verified legacy migration against a real Linux
  Secret Service session.
- Prove missing/locked/unavailable Secret Service keeps daemon startup healthy
  and cloud authorization fail-closed.
- Update technical design and QA documentation. **Complete.**

Gate evidence: the Linux store now speaks the freedesktop.org Secret Service
protocol directly over session D-Bus with bounded non-interactive operations.
On the real Linux desktop session, write/read/delete and verified legacy
migration passed while `secret-tool` was absent. A deliberately missing session
bus was normalized as vault unavailable; `AuthManager.initialize()` still
created/loaded local identity and exposed no cloud Agent authority. Locked
collections and non-root prompt paths are rejected without requesting an
interactive unlock.

## Historical deferred Headless Linux cloud phase

Task 68 intentionally shipped the following temporary boundary:

- a Headless Linux Agent without an unlocked user-session Secret Service started
  normally and kept the daemon and Local Gateway available;
- Agent cloud authorization failed closed, with no restart loop and no plaintext
  or lower-precedence fallback;
- installing `secret-tool` or a desktop keyring package alone was not presented
  as a supported unattended-cloud solution;
- durable cloud pairing/reconnection after unattended restart was deferred.

Task 81 supersedes that boundary with an owner-protected file backend selected by
capability probe, verified migration, and clean-host reboot evidence for durable
Headless cloud pairing. The exploratory Gate L3 TPM result remains historical
evidence: that Ubuntu 22.04 host exposed TPM devices, but the unprivileged Sanad
user service could not access them and no encrypted systemd credential utility
was available. Task 81 did not adopt an insecure plaintext workaround.

### Gate L3 — Current-release Linux packaging and lifecycle

- The Agent's direct D-Bus implementation is pure Dart and introduces no
  `secret-tool` executable or native libsecret development dependency.
- Source and compiled Agent paths share the same store selection and failure
  semantics.
- Existing installer replacement/rollback and service lifecycle remain
  unchanged; no migration deletes plaintext before verified vault read-back.
- Headless secure provisioning and lifecycle are outside this release as stated
  above. **Complete for the current-release Linux desktop scope.**

### Gate L4 — Linux completion review

- Bounded full Agent analysis passed.
- Focused Secret Service and authentication tests passed, including real Linux
  D-Bus write/read/delete, verified legacy migration, and missing-session-bus
  startup containment.
- Technical, QA, product, operator, and task documentation state the shipped
  desktop behavior and the deferred headless limitation.
- `graphify update .` could not run because Graphify is not installed in this
  environment and this worktree has no existing `graphify-out/graph.json`; this
  does not affect source verification.
- User reviewed and approved deferring Headless Linux and proceeding to Windows.
  **Complete.**

## Authorized Windows Phase

The Linux desktop phase is complete and the user explicitly approved committing
and pushing this branch, then continuing Windows in a dedicated worktree on the
Windows machine. The Windows session owns real DPAPI, package, clean-machine,
upgrade, rollback, and uninstall verification. It must not infer Windows success
from Linux-hosted tests.

Reading Windows code is not platform verification, and Task 68 cannot be closed
until that separately approved Windows phase passes.

## Windows Implementation Gates

### Gate W1 — Reproduction and product contract

- Run the real DPAPI write/read/delete test on Windows under an isolated Sanad
  Home and prove the persisted file contains no plaintext. **Complete.**
- Reproduce verified legacy `auth.json` migration and corrupt/unreadable DPAPI
  ciphertext behavior on Windows. **Complete.**
- Audit clean install, reinstall, upgrade, rollback, Scheduled Task restart, and
  uninstall behavior without modifying the normal user Sanad Home or service.
- Record package and lifecycle gaps before changing product code. **Complete.**

Initial Windows triage found that native DPAPI round-trip succeeds on Windows 11
under the current user and the owner-only Sanad Home boundary. The remaining W1
work must prove process/restart persistence, verified migration, fail-closed
corruption, and product lifecycle behavior. The canonical PowerShell installer
also contains a version-specific warning string instead of deriving the version
from the verified manifest, and its rollback path requires explicit proof that a
newly registered Scheduled Task cannot remain after a later installation failure.
The installer now derives its warning version from the verified manifest and
removes a Scheduled Task created by a failed first-install attempt before
restoring the prior executable. Static installer guards and PowerShell parsing
pass; no normal user task or installed binary was replaced during this worktree
verification.

The live Windows 11 reproduction also exposed a three-hour workstation clock
skew. DPAPI successfully restored the P-256 key, but Portal rejected its DPoP
`iat` as `invalid_dpop_proof` before issuing a Device Credential. The Agent now
calibrates from the authenticated HTTPS Portal `Date`, vault-persists only the
non-secret offset after verification, and applies it to Portal and Gateway
proofs. Co-located login then persisted a second DPAPI ciphertext entry; after a
daemon restart, the Agent recovered both credential and offset and the Cloud
Gateway accepted registration.

### Gate W2 — DPAPI identity and recovery

- Prove separate-process persistence for Agent private-key and Device Credential
  entries under the same Windows user and Sanad Home.
- Prove legacy plaintext is deleted only after DPAPI write/read verification.
- Prove corrupt, unreadable, or wrong-user DPAPI ciphertext leaves local startup
  healthy, clears cloud authority, and preserves retryable migration/logout state.
- Prove delete and logout remain absent after daemon restart.

**Complete.** Real Windows DPAPI covered ciphertext-only write/read/delete,
verified legacy migration, corrupt-ciphertext startup containment, real
co-located Device Authorization, and credential/offset recovery through daemon
restart. Existing logout and pending-logout tests cover deletion persistence.

### Gate W3 — Windows package and lifecycle

- Build and exercise the official Windows Agent artifact and Client installer on
  an isolated Windows profile or clean VM with platform protection enabled.
- Prove clean install, reinstall, upgrade, failed-update rollback, reboot startup,
  and uninstall while retaining the documented Sanad Home boundary.
- Verify no partial Scheduled Task or installed application remains after a
  failed first install or uninstall, and no plaintext secret appears in process
  arguments, logs, temporary files, package metadata, or diagnostics.

### Gate W4 — Windows completion review

- Run bounded Agent analysis and focused authentication, DPAPI, service, update,
  and installer verification.
- Record real Windows version, package identity, lifecycle checkpoints, and
  sanitized evidence in the Windows QA documentation.
- Update technical, operational, user, QA, release, and task documentation to
  match the verified behavior before closing Task 68.

## Verification Matrix

- Linux desktop: Secret Service available, absent, locked, and recovered.
- Linux source and compiled Agent: no `secret-tool` installation required.
- Task 68 Headless baseline: no D-Bus/Secret Service remained crash-free and
  cloud-fail-closed. Task 81 supersedes the former local-only/deferred boundary.
- Authentication: new identity, legacy migration, pairing, Portal authorization,
  gateway proof, pending logout, logout, backend reload, and no downgrade.
- Lifecycle: clean install, reinstall, upgrade from older release, rollback,
  uninstall, retained data, and secure plaintext-to-vault migration.
- Leakage canaries: process arguments, environment boundaries, logs, errors,
  status output, config, package metadata, and temporary files.
- Supervisor: daemon remains healthy and does not enter a restart loop when cloud
  credential storage fails.

All Dart and Flutter commands use FVM. Analyzer/test output is bounded while
preserving exit status. No system package is installed manually during clean
machine reproduction.

## Status

- Phase 1 startup containment: complete.
- Reference grounding: complete.
- Linux desktop direct Secret Service implementation and real-session
  verification: complete.
- Linux packaging/runtime dependency scope: complete; `secret-tool` is not
  required.
- Headless Linux secure unattended cloud: deferred when Task 68 closed; Task 81
  now supersedes this item with durable owner-file credentials and service support.
- Windows DPAPI implementation and real source-runtime verification: complete.
- Windows packaged clean-machine candidate lifecycle: remains a release-artifact
  gate and is not claimed by this source worktree verification.

**Task 68 implementation remaining: 0%.** Its Linux desktop and Windows vault
scope is complete. Task 81 subsequently completed the Headless Linux capability
that Task 68 had deferred. A future Windows candidate still runs the existing
clean-machine release gate before publication.

## Definition of Done

- Linux desktop works after normal product installation without user-run
  dependency commands.
- Task 68 kept Headless Linux without Secret Service stable and cloud-fail-closed;
  Task 81 later added the supported owner-file cloud path without plaintext downgrade.
- No secure configuration silently downgrades to plaintext.
- Vault/backend failure cannot prevent daemon startup or cause a restart loop.
- Cloud authentication remains fail-closed whenever selected credential
  material cannot be loaded and verified.
- Current-release Linux desktop source, migration, and failure behavior are
  covered by automated and real-platform evidence.
- Linux desktop completion receives user approval before Windows work.
- The later Windows phase proves DPAPI and official Windows lifecycle behavior on
  a real Windows machine.
- Technical, operational, user, QA, and task documentation match shipped
  behavior.
