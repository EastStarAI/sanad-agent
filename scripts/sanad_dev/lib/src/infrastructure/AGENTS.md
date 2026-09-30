# sanad-dev Infrastructure Contract

This contract governs foundational models, storage, process execution, and configuration primitives in `scripts/sanad_dev/lib/src/infrastructure/`.

---

## 1. Scope & Ownership
* `secure_runtime_file.dart`: POSIX/Windows atomic file operations and permissions.
* `local_gateway_credential.dart`: Gateway credential loading and HTTP authorization.
* `client_launch_profile.dart`: Extraction and reconstruction of Flutter compile-time defines.
* `cloud_endpoints.dart`: Cloud environment resolution.
* `component_journal.dart`: File-based, process-attached journal logging.
* `runtime_context.dart`: Worktree path, branch, and port calculation models.
* `path_equivalence.dart`: Host-aware canonical path identity and Windows device-prefix normalization.
* `runtime_component_control.dart`: Component control IPC manifest structures.
* `startup_attempt.dart`, `startup_probe.dart`: Startup attempt and probe primitives.
* `terminal_launcher.dart`: External OS terminal window launching.

---

## 2. Invariants & Security Laws
* **Owner-Only Runtime Files:** All launcher records, IPC requests, and journals must be written using atomic file operations with strict owner-only permissions rooted at the owning Sanad Home or runtime directory.
* **Credential Isolation:** The Local Gateway credential must be transmitted strictly in the authorization header. It must never be written to a journal, command argument, log output, or unauthenticated file.
* **Windows Shell Execution Constraint:** When spawning `Process.start` for executable batch scripts on Windows, `runInShell: Platform.isWindows` must be set.
* **Hermetic Tests:** Automated tests must never contact real production cloud endpoints or rely on live network availability.
