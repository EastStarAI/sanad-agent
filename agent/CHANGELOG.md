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
