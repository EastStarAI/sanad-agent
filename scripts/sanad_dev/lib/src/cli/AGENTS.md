# sanad-dev CLI Routing Contract

This contract governs the CLI parsing, usage rendering, and dispatch boundary in `scripts/sanad_dev/lib/src/cli/`.

---

## 1. Dispatch & Entry Boundary
* `cli.dart` is restricted to the `main` entry point and command routing. It must remain at or below 250 lines.
* Parsing and usage rendering are separated into `cli_parser.dart` and `cli_help.dart`.
* Common runtime and home resolution helpers live in `runtime_selection.dart`.

---

## 2. Invariants & Safety Laws
* **Mutation-Free Parsing & Help:** Neither `cli_parser.dart` nor `cli_help.dart` may probe Git, inspect running processes, bind ports, read credentials, or mutate runtime state.
* **No-Argument Safety:** Invocations with no arguments or with `--help` / `-h` must remain strictly mutation-free, print usage instructions, and exit cleanly with code `0` or `1`.
* **Strict Parameter Validation:**
  * `--home` requires `"user"` or an absolute filesystem path.
  * `--client-instance` requires a Client run target.
  * `--background` cannot be combined with `--dry-run` or `--internal-background`.
  * Incompatible argument combinations must fail closed with exit code `64` and a descriptive message on `stderr`.
* **Stable Command Surface:** CLI commands, flags, aliases, defaults, and error text must remain backwards-compatible.
