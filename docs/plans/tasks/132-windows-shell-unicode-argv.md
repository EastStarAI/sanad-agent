---
title: "Task 132: Windows Shell Start-Gate & Unicode Argv Fixes"
description: "Fix Windows shell execution corruption for non-ASCII (Arabic) arguments, repair execution isolation path traversal test on Windows, and add numeric exit_code to shell execution result payload."
status: "in_review"
current_gate: "Implementer round 1"
priority: "blocker"
depends_on: "Release candidate 182d6a4"
file_budget: 10
---

# Task 132: Windows Shell Start-Gate & Unicode Argv Fixes

## 1. Problem & Live Evidence

Live testing on Windows 11 (candidate `182d6a4`, 2026-10-22) revealed three issues:

1. **W2-8 Unicode Command Argument Corruption:**
   - Non-ASCII (e.g. Arabic) arguments passed to child programs via `DirectExecutionBackend` on Windows were corrupted.
   - Under Windows `cmd.exe`, the active console code page defaults to OEMCP (typically CP437 on US systems). When a `.cmd` batch file is executed, `cmd.exe` parses command lines using the active code page at read time.
   - A single script with UTF-8 bytes causes Arabic characters (e.g. `مرحبا`) to be decoded under CP437 into mojibake (`╪╡└ê…`).
   - Running `chcp 65001` *inside* the same command line (e.g. `chcp 65001 && dart run ...`) does not fix the corruption because `cmd.exe` decodes the entire line from disk into its execution buffer before executing `chcp 65001`.
   - Echo and redirection to disk were byte-faithful, but arguments passed to spawned child programs (`GetCommandLineW`) arrived corrupted.

2. **Test Defect on Windows Paths:**
   - `test/capabilities/execution_isolation_test.dart:301` ("cwd rejects a sibling root that shares the workspace prefix") constructed `Directory('${workspace.path}/pkg')` using string concatenation with a forward slash.
   - On Windows, this created mixed-separator paths (`C:\Temp\ws/pkg`), and `split(Platform.pathSeparator).last` failed to correctly isolate the directory basename.

3. **Missing Exit Codes in Tool Result Payload:**
   - `DirectExecutionBackend.finishWith` (line 176) included only `isError`, `output`, `duration_ms`, `cleanup_outcome`, and `terminal_reason`.
   - Callers and diagnostic consumers lacked the numeric process exit status on natural completion.

## 2. Architecture & Design

### 2.1 Dual-Script Windows Shell Execution (`WindowsShellWrapper`)

To guarantee UTF-8 command parsing without breaking ASCII commands, the start gate, exit codes, or process tree ownership:

1. **Pure-ASCII Wrapper (`command.cmd`):**
   - The entry batch file executed by `COMSPEC /d /q /c` contains exclusively ASCII characters (bytes < 128). ASCII bytes are decoded identically by every Windows code page.
   - **Line 1:** `@%SystemRoot%\System32\chcp.com 65001>nul 2>&1` switches the console code page to UTF-8 before reading any non-ASCII command text, resolving `chcp.com` directly from System32 without depending on the child `PATH`.
   - **Start Gate Loop:** Waits for the daemon to write `owned.ready` (process tree ownership established) before executing any user command, using `%SystemRoot%\System32\ping.exe` directly:
     ```cmd
     :wait_for_owner
     if not exist "%~dp0owned.ready" (
       >nul 2>&1 %SystemRoot%\System32\ping.exe -n 2 127.0.0.1
       goto wait_for_owner
     )
     ```
   - **Errorlevel Reset:** Executes `(call )` immediately before `call` of the payload file. This resets `%errorlevel%` to 0 using the built-in cmd idiom so no wrapper helper execution or unrecognized command status leaks into the payload's reported exit code.
   - **Payload Delegation:** Calls the separate payload file via `call "%~dp0payload.cmd"`. Because code page 65001 is already active when `call` opens `payload.cmd`, `cmd.exe` parses the payload file from byte 0 under UTF-8.
   - **Exit Code Propagation:** Finishes with `exit /b %errorlevel%`, ensuring the exact exit code of the child command is returned to the process caller.
   - **Path Robustness via `%~dp0`:** Uses `%~dp0` to reference sibling files in the temp directory. This prevents path formatting bugs (spaces, `%` expansion) and ensures the wrapper remains 100% pure ASCII even if the user profile directory contains Arabic or other non-ASCII characters (e.g. `C:\Users\أحمد\AppData\Local\Temp`).

2. **Verbatim UTF-8 Payload (`payload.cmd`):**
   - Holds the model/user command verbatim.
   - Encoded as UTF-8 **without BOM** (a UTF-8 BOM `0xEF 0xBB 0xBF` would be treated as invalid syntax on the first command line).
   - Normalizes line breaks to CRLF (`\r\n`) so multiline commands execute cleanly under `cmd.exe`.

### 2.2 Execution Isolation Test Fix

- In `agent/test/capabilities/execution_isolation_test.dart`:
  - Replaced `Directory('${workspace.path}/pkg')` with `Directory(p.join(workspace.path, 'pkg'))`.
  - Replaced path split with `p.basename(inside.path)`.
  - Added `import 'package:path/path.dart' as p;`.

### 2.3 Additive Numeric `exit_code` Field

- In `DirectExecutionBackend.finishWith`:
  - Added optional `int? exitCode` parameter.
  - Included `'exit_code': ?exitCode` in the returned JSON payload.
  - Stamped when the process completes naturally (`_ShellWaitCompleted(:final exitCode)`).
  - Omitted (null) when the command timed out, was cancelled, or failed to spawn (where no observed exit status exists).
  - Fully backward-compatible and additive for clients and consumers.

## 3. Definition of Done

- [x] `WindowsShellWrapper` implementation with pure-ASCII wrapper, UTF-8 payload without BOM, `%~dp0` sibling references, and exit code propagation.
- [x] `DirectExecutionBackend` wires `writeWindowsShellFiles` on Windows.
- [x] Additive `exit_code` included on natural completion and omitted on timeout/cancellation.
- [x] `execution_isolation_test.dart` uses `p.join` and `p.basename`.
- [x] Dedicated unit tests in `windows_shell_wrapper_test.dart` covering encoding, BOM absence, CRLF normalization, Arabic preservation, and ASCII purity.
- [x] `shell_execute_tool_test.dart` asserts `exit_code: 0` on success and `exit_code: 1` on error.
- [x] `shell_execute_cancellation_test.dart` asserts omission of `exit_code` on cancellation.
- [x] `fvm dart analyze` clean across `agent/`.
- [x] Full agent test suite passes under isolated `SANAD_HOME` / `SANAD_STATE_HOME`.
- [x] Contracts and technical docs updated: `docs/technical/execution_trust_and_permission_authority.md`, `agent/lib/capabilities/AGENTS.md`, `agent/lib/capabilities/tools/AGENTS.md`.

## 4. Manual Windows Verification Steps

To manually verify these fixes on Windows 11:

### Prerequisites on Windows 11
1. Open PowerShell or Command Prompt.
2. Ensure active code page is the default (e.g. `chcp` shows `437`).
3. Check out branch `fix/windows-shell-unicode-argv`.
4. Ensure dependencies are resolved: `cd agent && fvm dart pub get`.

### Verification Step 1: Automated Unit & Capabilities Tests
Run the affected test suites:
```cmd
cd agent
fvm dart test test/capabilities/windows_shell_wrapper_test.dart
fvm dart test test/capabilities/execution_isolation_test.dart
fvm dart test test/capabilities/shell_execute_tool_test.dart
fvm dart test test/capabilities/shell_execute_cancellation_test.dart
```
**Expected:** All tests pass, including Windows-specific tests (no failures, no path mismatch).

### Verification Step 2: Unicode Argument Passing (Live W2-8 Reproduction & Fix)
Create a test script `echo_args.dart` that prints its arguments:
```dart
// test_args.dart
void main(List<String> args) {
  print('ARG_COUNT: ${args.length}');
  for (var i = 0; i < args.length; i++) {
    print('ARG[$i]: ${args[i]}');
  }
}
```
Run through `ShellExecuteTool` or standalone CLI with an Arabic argument:
```cmd
fvm dart run bin/sanad_agent.dart run --execution-root . "run shell_execute with command: dart run test_args.dart \"مرحبا بالعالم\""
```
**Expected Output:**
- `ARG[0]: مرحبا بالعالم`
- Output must NOT contain mojibake like `╪╡└ê…`.
- Result JSON payload contains `"exit_code": 0`.

### Verification Step 3: Exit Code Reporting
Run commands with explicit exit codes:
```cmd
REM Success case (exit 0)
fvm dart test test/capabilities/shell_execute_tool_test.dart -n "result includes duration_ms and omits isError on success"

REM Non-zero error case (exit 1)
fvm dart test test/capabilities/shell_execute_tool_test.dart -n "result includes isError: true and duration_ms on non-zero exit"
```
**Expected Output:**
- Success command returns payload with `"exit_code": 0` and no `"isError"`.
- Error command returns payload with `"exit_code": 1` and `"isError": true`.

### Verification Step 4: Start Gate & Cancellation
Run long-running command and trigger cancellation or timeout:
```cmd
fvm dart test test/capabilities/shell_execute_cancellation_test.dart
```
**Expected Output:**
- All tests pass; processes are properly killed via process tree controller; cancelled commands do not hang.

## 5. Round Log

### Round 1 — Implementer (macOS)
- Analyzed base diff: previous implementer had drafted `windows_shell_wrapper.dart` and edits to `direct_execution_backend.dart` and `execution_isolation_test.dart`.
- Fixed analyzer errors in `execution_isolation_test.dart` by adding `import 'package:path/path.dart' as p;`.
- Enhanced `windows_shell_wrapper.dart`:
  - Adopted `%~dp0` for sibling file references (`%~dp0owned.ready`, `%~dp0payload.cmd`). This guarantees the wrapper file is 100% pure ASCII even if the user temp path has Arabic characters or spaces.
  - Added line break normalization in `renderPayload` to ensure CRLF is consistent for `cmd.exe`.
  - Used `p.windows.normalize(p.windows.join(...))` for Windows path generation.
- Added comprehensive unit test suite in `agent/test/capabilities/windows_shell_wrapper_test.dart` (7 tests covering pure ASCII invariants, BOM absence, path helpers, CRLF normalization, and file writing).
- Updated `shell_execute_tool_test.dart` to assert `exit_code: 0` on success and `exit_code: 1` on failure.
- Updated `shell_execute_cancellation_test.dart` to assert `exit_code` omission on cancellation.
- Updated documentation and contracts:
  - `docs/technical/execution_trust_and_permission_authority.md` (§4 Where commands run).
  - `agent/lib/capabilities/AGENTS.md` (§Replay and Identity).
  - `agent/lib/capabilities/tools/AGENTS.md` (§Shell Execution).
- All affected tests passed (36 passed, 4 skipped for non-Windows/Linux).
- `fvm dart analyze` reported 0 issues across `agent/`.

### Round 2 — Implementer (macOS delta: wrapper errorlevel leak)
- **Live Windows 11 Verification Findings:**
  - W2-8 UTF-8 argv fix verified live on Windows 11 under default code page 437: Arabic argument hex was byte-exact, and natural exit codes 0 and 3 verified correct.
  - Live regression identified in `shell_execute_tool_test.dart` ("Windows shell child receives the resolved system PATH"): failed at `shell_execute_tool_test.dart:152` with `isError: true` and exit code 9009 (real result `{"isError":true,"output":"C:\\resolved\\bin\r\n","exit_code":9009}`).
  - **Root Cause:** When the resolved child `PATH` did not include System32 (e.g. `C:\resolved\bin`), the wrapper's bare `chcp` invocation and the `ping` wait loop failed with errorlevel 9009 ("not recognized"). Because the child payload `echo %PATH%` is a cmd.exe internal command that does not reset `%errorlevel%`, `exit /b %errorlevel%` leaked the wrapper's own failure code 9009 as the child's exit status.
- **Fix in `agent/lib/capabilities/execution/windows_shell_wrapper.dart`:**
  - Invoked internal helpers by absolute path from `%SystemRoot%\System32\` (`@%SystemRoot%\System32\chcp.com 65001>nul 2>&1` and `>nul 2>&1 %SystemRoot%\System32\ping.exe -n 2 127.0.0.1`), removing dependency on child `PATH`.
  - Added `(call )\r\n` immediately before `call "%~dp0$payloadFileName"` to reset `%errorlevel%` to 0 via cmd built-in syntax before executing the payload, guaranteeing the reported exit status is solely the payload's own exit status.
  - Kept start gate (`%~dp0owned.ready`), `%~dp0` sibling paths, CRLF, and UTF-8 without BOM unchanged.
- **Tests Updated:**
  - `agent/test/capabilities/windows_shell_wrapper_test.dart`: asserted wrapper uses `%SystemRoot%\System32\chcp.com` and `%SystemRoot%\System32\ping.exe`; asserted `(call )\r\n` comes immediately before `call "%~dp0payload.cmd"`; verified wrapper is pure ASCII.
- **Documentation Updated:**
  - `agent/lib/capabilities/AGENTS.md` (§Replay and Identity).
  - `agent/lib/capabilities/tools/AGENTS.md` (§Shell Execution).
  - `docs/technical/execution_trust_and_permission_authority.md` (§4 Where commands run).
  - `docs/plans/tasks/132-windows-shell-unicode-argv.md` (Design §2.1 and Round 2 log).
