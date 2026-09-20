# Task 56 — Device Name Editing

## Goal Description

Restore device renaming in the Settings device Overview. A user can open an English rename dialog from an edit icon beside the device name, validate and submit a new name, and see the authoritative inventory update everywhere that displays the device.

The mutation remains account-owned: a cloud device uses its database id, while the merged local representation uses its `cloudDeviceId`. A local-only device without a cloud identity is not presented as renameable because there is no durable account record to update.

## Implementation Tasks

1. Expose an asynchronous rename operation through `DeviceCubit`, `IDeviceRepository`, and `DeviceRepositoryImpl`.
2. Correlate `update_device` requests and `device_updated` responses in `DeviceManager`, including explicit errors, timeout cleanup, and merged-local cloud identity resolution.
3. Add backend request correlation and reject blank or oversized names at the authoritative boundary.
4. Add the edit affordance and rename dialog to Device Overview with focus, validation, progress, success, and failure states.
5. Update product and protocol documentation for rename ownership and local-only behavior.
6. Add focused client unit/widget tests and backend handler tests.

## Definition of Done

- [x] A renameable device shows a pen icon beside its name in Overview.
- [x] The dialog starts with the current name and supports keyboard submission and cancellation.
- [x] Blank names and names longer than 255 characters cannot be submitted.
- [x] The mutation waits for a correlated authoritative response and exposes backend failures or timeouts.
- [x] A merged local device sends its cloud device id, never its local hardware identity.
- [x] A local-only device does not offer a misleading rename action.
- [x] Successful updates refresh Overview, Settings navigation, and active-device projections through the existing inventory stream.
- [x] Focused Flutter unit/widget tests and backend unit tests pass.
- [x] Flutter analysis passes and changed Dart files are formatted.
- [x] Product, protocol, QA, and feature contract documentation is current.

## Success Test Scenario

1. Run `fvm flutter analyze` from `sanad-agent/client`.
2. Run focused tests for `DeviceManager`, `DeviceCubit`, and the Settings rename dialog.
3. Run the backend device-handler unit tests from the backend virtual environment.
4. Open Settings, select a cloud-backed device, choose Overview, press the pen icon, rename the device, and verify the new name appears in both Overview and Settings navigation.
5. Select a merged local/cloud device and verify the same flow persists through its cloud id.
6. Verify a local-only device has no edit action.
