# sanad-dev Developer Actions Contract

This contract governs developer observability, interactive controls, and UI automation forwarding in `scripts/sanad_dev/lib/src/developer/`.

---

## 1. Scope & Ownership
* `developer_journal.dart` owns journal streaming, tailing, bounded log reads, and terminal key listening.
* `developer_client.dart` owns Client attach actions (hot reload `r`, hot restart `R`), DevTools launch, and compile-time profile validation.
* `developer_agent.dart` owns Agent log retrieval and authenticated `/restart` requests.
* `developer_ui_driver.dart` owns UI automation and Flutter Driver command forwarding.

---

## 2. Invariants & Safety Laws
* **Bounded Output Invariant:** Agent tool calls reading logs must always use bounded reads (`-n <lines>`). Agents must never invoke follow mode (`-f`/`--follow`), which is reserved exclusively for human interactive terminals.
* **Lossless Client Profile Re-use:** Client attach commands (`reload`, `restart`) must recover the live process argument vector from an OS-native source and verify its exact launch profile, worktree marker, gateway port, and preference namespace before attaching.
* **Supervised Agent Restart:** Agent restarts must trigger the `/restart` HTTP endpoint against the supervisor (`HotRestartManager`) rather than killing processes at the OS level.
* **Deterministic UI Driver Targeting:** UI driver commands route automatically only when exactly one matching launcher-owned driver Client exists; multiple managed Clients require an explicit VM endpoint (`-p <port>`).
