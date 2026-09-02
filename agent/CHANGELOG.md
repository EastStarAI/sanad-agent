## 1.0.7

- Added durable conversation replay, materialized forks, paginated history, and synchronized live-history recovery (#125, #127, #128, #131).
- Added run-scoped cancellation, safe forced-shutdown recovery, and protection against replaying active provider requests after controlled restart (#112, #117, #124).
- Added durable model-aware context compaction and contained provider model-refresh failures (#118, #123).
- Added secure device-scoped workspace and MCP control plus durable Linux headless Agent installation (#120, #121).
- Hardened `sanad-dev` runtime ownership, background startup, and multi-driver control (#126).
- Added deterministic release identity preparation and fail-closed metadata verification (#132).

## 1.0.6

- Hardened macOS Agent runtime trust verification to enforce Developer ID publisher requirements (#105).
- Strengthened installer pairing contract guards and release manifest verification (#105).

## 1.0.5

- Upgraded macOS Keychain backend to Apple `SecItem` API, sanitized auth storage serialization, and automated CLI PATH configuration (#102).
- Serialized concurrent Agent permission prompts per session to prevent approval race conditions (#99).
- Added Flutter VM driver CLI for automated UI diagnostics and testing (#98).
- Updated macOS release CI runner to macos-26 for Xcode 26 support (#101).

## 1.0.4

- Corrected the Windows release smoke gate so PowerShell uses a writable Sanad Home variable instead of the reserved `$HOME` variable.
- Supersedes the unpublished v1.0.3 candidate; no v1.0.3 GitHub Release or Production asset was created.

## 1.0.3

- Replaced transferable OAuth polling with S256 PKCE for Client sign-in and P-256 proof-bound Device Authorization for headless Agents.
- Bound one-command pairing and Gateway registration to fresh key-possession proofs, with vault-backed Agent credentials and fail-closed legacy-token rejection.
- Added verified mobile callback ownership, safer runtime recovery, external-workspace permission gates, and the latest Client navigation and interaction improvements.

## 1.0.2

- Serialized native desktop authentication and token refresh with cross-process OS file locks (`shared/auth_lock`).
- Hardened `sanad-dev switch` runtime handoff to automatically prepare target checkout workspaces.
- Synchronized release manifest contract and version definitions with Client 1.0.2+3.

## 1.0.1

- Hardened Sanad Home, Local Gateway, authentication, and remote-management boundaries.
- Improved session recovery, provider setup, workspace handling, and typed tool history.
- Completed verified desktop Client-Agent installation, update, and rollback lifecycle.
- Added form-first MCP server configuration with runtime isolation.

## 1.0.0

- Initial version.
