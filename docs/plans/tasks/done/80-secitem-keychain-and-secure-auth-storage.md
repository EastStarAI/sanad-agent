# Task 80 — SecItem Keychain Upgrade, CLI PATH Setup, and Secure Auth Storage

## Problem

1. **Deprecated macOS Keychain API (`SecKeychain*`):**
   `MacOsKeychainAgentSecretStore` currently uses deprecated `SecKeychainFindGenericPassword` / `SecKeychainAddGenericPassword`. On macOS, these legacy APIs interact with file-based keychains and trigger modal password prompts with ACL mismatch whenever a binary signature changes or runs non-interactively, causing startup timeouts in the Flutter Client (`_waitForTargetVersion`).
2. **Missing `sanad` CLI on `PATH` after Client-driven Installation:**
   When the user installs the local Agent via the Flutter Client ("Run Locally"), the binary is downloaded to `~/.sanad/bin/sanad`, but `~/.sanad/bin` is not added to user shell profiles (`~/.zshrc`, `~/.bash_profile`), causing `sanad` to be unrecognized in terminal sessions.
3. **Session Token Hygiene and Colocated Coordination:**
   The user session tokens (`access_token`, `refresh_token`) should remain in secure storage and not be exposed in plaintext JSON files on disk, while preserving the ability for the Client to pair with and synchronize login/logout lifecycle with the local Agent seamlessly on the same machine.

## Goals

1. **Modern `SecItem*` Data Protection Keychain on macOS:**
   - Migrate `MacOsKeychainAgentSecretStore` to native `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete` with `kSecAttrAccessibleAfterFirstUnlock`.
   - Prevent interactive modal blocking prompts during daemon startup.
2. **Automatic Terminal PATH Configuration:**
   - On local Agent installation, safely ensure `~/.sanad/bin` is present in standard shell profile files (`~/.zshrc`, `~/.bash_profile`, `~/.bashrc`) or symlinked where possible.
3. **Robust Colocated Authentication & Standalone Operation:**
   - Keep Agent fully functional in standalone/headless environments without Client.
   - Synchronize login/logout lifecycle locally over loopback and secure state signals.
4. **Comprehensive Real Verification:**
   - Unit tests covering `SecItem` storage, PATH configuration, and auth managers.
   - Real E2E verification using browser automation with `~/aatia-automation-profile` to test full login, pairing, and CLI command execution.

## Gates

### Gate 1: SecItem macOS Vault Implementation
- [x] Implement `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete` bindings in `agent/lib/core/auth/agent_secret_store.dart`.
- [x] Implement CoreFoundation helper wrappers for dictionaries, strings, and byte data.
- [x] Run and pass `agent/test/core/agent_secret_store_test.dart`.

### Gate 2: Automatic CLI PATH Configuration on Install
- [x] Add shell profile PATH helper in `agent/lib/core/setup/cli_path_manager.dart`.
- [x] Wire PATH installation into `service_manager.dart`.
- [x] Add unit tests for shell configuration (`cli_path_manager_test.dart`).

### Gate 3: Secure Auth Lifecycle & Colocated Synchronization
- [x] Verify `AuthManager` in `agent` handles headless and colocated state without plaintext token leakage.
- [x] Verify Client-Agent login and logout signal synchronization.
- [x] Run `agent` and `client` unit tests.

### Gate 4: Verification
- [x] Analyzer clean across `agent` and `client`.
- [x] 1136 `agent` tests passed.
- [x] `client` auth service unit tests passed.

