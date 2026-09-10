---
title: "Device Name Editing QA"
description: "QA scenarios and test matrices for verifying device renaming."
---

# Device Name Editing QA

## Automated Coverage

- The client manager sends the merged device's cloud id, trims the name, correlates success, updates inventory, and surfaces correlated errors.
- The device cubit delegates rename intent without owning a competing device store.
- The rename dialog starts with the current name, submits a trimmed replacement, remains open on failure, and is absent for a local-only device.
- The backend trims accepted names, echoes correlation fields, and rejects invalid or oversized values before persistence.

## Manual Regression Matrix

| Scenario | Expected result |
|---|---|
| Rename a remote cloud device | Overview and Settings navigation show the authoritative new name. |
| Rename the current merged local/Cloud device | The request targets `cloud_device_id`; the visible row retains its `hardware_id` identity and shows the new name. |
| Inspect a local-only device | No rename icon is shown. |
| Submit an unchanged or blank name | Rename remains disabled and no request is sent. |
| Gateway rejects or times out | The dialog remains open and displays the failure; the old name remains visible. |
| Another signed-in app is open | Its device inventory receives `device_updated` and shows the new name. |
