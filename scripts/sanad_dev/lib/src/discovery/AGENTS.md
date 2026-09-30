# sanad-dev Discovery Contract

This contract governs runtime process discovery, agent probing, and instance selection in `scripts/sanad_dev/lib/src/discovery/`.

---

## 1. Discovery Scope
* `process_discovery.dart` owns OS process table inspection and Flutter runner / DDS correlation.
* `agent_discovery.dart` owns local gateway credential discovery, health probing, and active-Home candidate inference.
* `instance_selection.dart` owns exact agent and client selection and ambiguity resolution.

---

## 2. Invariants & Discovery Laws
* **Real-Time Inspection:** Discovery must inspect live operating system process trees and HTTP/WebSocket endpoints in real time. It must never rely on stale cache files (`runtime.json`) or log redirection.
* **Read-Only Invariant:** Discovery operations are strictly read-only and must never kill processes, write launcher leases, or delete runtime records.
* **Network Privacy Protection:** Probing endpoints and exchanging health state over HTTP must transmit cryptographic one-way hashes (`workspace_hash`) and abstract state indicators (`state_mode`). Absolute paths or usernames must never be transmitted over the network.
* **Home Inference Precedence:** Discovery commands must honor an explicit `--home` selector. When absent, post-launch commands infer the active Home from the current workspace locator without mutating any runtime state.
