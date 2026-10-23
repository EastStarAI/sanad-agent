# Sanad 1.0.20

Sanad 1.0.20 ends the command-line hangs that affected 1.0.18 and 1.0.19, gives the macOS Agent one stable signing identity, and ties every `sanad` command to the Sanad Home it was asked to use.

## Command line

- **`sanad` no longer hangs on gateway commands.** In 1.0.18 and 1.0.19 a compiled `sanad` build could stop forever on gateway commands such as `session list`. Startup opened the Agent secret vault for every command, including commands that read no secret, and macOS answered a vault item created by a different code identity with a Keychain authorization dialog; the read blocked there before the process could serve anything, so an automation run waited on a prompt nobody could see. Commands that read no secret — `session`, `workspace`/`ws`, `memory`, `schedule list`, `skills list`, and the pure queries — no longer open the vault at all, and a process that skipped the vault refuses to fall back to plaintext secrets. A process may open a Keychain dialog only when it is the daemon or an interactive terminal invocation, so automation, `--json`, and `--quiet` never start a dialog and fail closed with a reason code instead (#271).
- **A command stays in the Sanad Home it was given.** `--home` and `SANAD_HOME` now resolve that Home's own local gateway endpoint, published as an owner-only runtime record when the daemon binds, before any default probe. A Home with no record, a stale or foreign record, an unreachable endpoint, or an endpoint that answers with another Home's identity fails closed with exit code 78 rather than reaching a different runtime. Inherited gateway variables no longer redirect a Home-selected call, and each Home carries its own token that only its own daemon may rotate (#268).
- **A busy daemon is no longer read as absent.** The forced-standalone ownership pre-check applied the 300 ms speculative probe bound to an endpoint it was explicitly pointed at, so a healthy but busy Home daemon could be missed and `--standalone` started a second runtime on a Home that already owned one. Mode resolution and the ownership check now share one run-scoped discovery instance that selects the deadline by probe scope: 2 s for a targeted probe, 300 ms for a speculative one (#264).

## macOS

- **The Agent has one stable signing identity.** `codesign` used to derive the Agent's signing identifier from the artifact file name, which carries the release version, so every release published a different designated requirement. macOS records that requirement as the trusted code of the Keychain items an application creates, so an item created by one version was never authorized for the next one, and an Agent without a user present could block on a prompt. Release signing now uses one workflow-level identifier, `com.eaststarai.sanad.agent`, which contains neither the version nor the architecture, and the signing step fails unless the signed binary reports exactly that identifier and a designated requirement naming it and the team. Installation and the updater keep verifying the Apple-anchored publisher instead of the identifier (#272).

### Upgrading from 1.0.18 or 1.0.19

Keychain items created by 1.0.18 and 1.0.19 name those binaries' exact old requirements. The first launch of this release may therefore still prompt once for such an item; choosing **Always Allow** adds the new, version-independent requirement to it, so every later release is already authorized. A fresh installation never prompts. Commands that never open the vault never reach this prompt.

## Developer tooling

- **`sanad-dev ui` actions are fast and verified.** Each action used to pay a full compile and VM reconnect, and some driver paths could hang, silently do nothing, or return stale evidence. Actions now reuse a cached native artifact keyed by source fingerprint, every action has a deadline (30 s by default) that exits 124 with a bounded diagnostic, `wait-for` is tree-driven, snapshots carry a monotonic `generation` and a tree `signature`, and batch steps can chain verification options in one call (#266).
- **Task records match reality.** The Task 78 record now shows its completed live acceptance and merge instead of a pending state (#265).

## Pending in this preparation branch

> [!IMPORTANT]
> **REPLACE THIS BLOCK BEFORE PUBLICATION — `session steer` / `session retry` (#269).** PR #269 (`feat(cli): add non-interactive session steering`) merges after this preparation commit. Its merged behaviour is described here in a follow-up edit, and this placeholder block is removed in the same edit. Release notes containing this block must not be published.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.20` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.20` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `21` corresponds to marketing version `1.0.20`.
