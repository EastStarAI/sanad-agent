# sanad-dev Runtime Domain Contract

This contract governs runtime state projection, ownership assessment, lifecycle commands, and source handoff in `scripts/sanad_dev/lib/src/runtime/`.

---

## 1. Domain Structure
* **`ownership/`**: Owns launcher record models, lease validation, runtime process state projection, and managed-ownership assessment.
* **`lifecycle/`**: Owns foreground run orchestration, background launch, status projection, component control, doctor repairs, orphan cleanup, takeover, and wait helpers.
* **`switch/`**: Owns switch admission, process termination waits, transaction control, target launch, rollback, and tool-result checkpointing.

---

## 2. Invariants & Operational Laws
* **Strict Lease Verification:** Managed mutation against an Agent or Client requires full agreement between the live launcher lease, PID, process identity, runtime nonce, launcher id, workspace hash, and exact client inventory. Ambiguity or mismatch must fail closed.
* **Component Lifecycle Independence:** Starting, stopping, or failing one component (Agent or Client) must not involuntarily terminate a healthy sibling component.
* **Resumable Stop:** Normal Agent stop uses the daemon checkpoint drain. `--force` is valid only for Agent-owning stop targets and signals bounded cancellation.
* **Autonomous Switch Prohibition:** AI agents must never invoke `sanad-dev switch` autonomously; execution requires direct, explicit user authorization and disclosing shared-session impacts.
* **Source Switch Transaction Safety:**
  * Requires a complete matched Agent/Client group.
  * Rejects an already-running target worktree.
  * Retains the original Sanad Home, local gateway port, client VM ports, and preferences namespace.
  * Brackets handoff with status verification before and after execution.
  * Automatically rolls back to the complete previous group if target startup fails.
