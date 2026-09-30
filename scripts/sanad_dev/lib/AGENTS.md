# sanad-dev Production Architecture Contract

This contract governs the production Dart code within `scripts/sanad_dev/lib/`.

---

## 1. Composition Root and Root Files
* `sanad_dev_cli.dart` is the sole composition root for the `sanad-dev` command-line executable.
* Root-level `.dart` files other than `sanad_dev_cli.dart` require a tracked external consumer and must remain thin export-only forwarders to their owning `src/` implementation. Package-internal code or tests alone do not justify a root facade.
* Modules under `src/` and package-owned tests import the narrow owning implementation directly; they must not route dependencies back through root compatibility forwarders.
* No feature logic, process discovery, HTTP transport, or journal storage may be placed directly at `lib/` root.

---

## 2. Dependency Direction Laws
1. **Pure Models and Parsers:** Modules under `src/infrastructure/` and `src/cli/` must not depend on runtime command handlers or lifecycle orchestration.
2. **Discovery Boundary:** Modules under `src/discovery/` may depend on runtime context and secure infrastructure primitives, but must not call lifecycle command handlers or invoke mutation actions.
3. **Ownership Assessment:** Ownership assessment under `src/runtime/ownership/` may consume discovered models from `src/discovery/`, but discovery must never mutate ownership records.
4. **Command Handlers:** Handlers under `src/runtime/lifecycle/`, `src/runtime/switch/`, and `src/developer/` may compose discovery, ownership, journal, and process-control services.
5. **No Composition Root Leakage:** Submodules under `src/` must never import `sanad_dev_cli.dart`.

---

## 3. Size and Cohesion Guardrails
* No handwritten production Dart file under `scripts/sanad_dev/lib/` may exceed 700 lines.
* `cli.dart` must remain at or below 250 lines and serve strictly as a top-level dispatcher.
* Every module must own a single cohesive responsibility matching its domain folder.
