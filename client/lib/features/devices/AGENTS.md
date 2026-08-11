# Devices Feature Contract

## Scope
This contract applies to `client/lib/features/devices/`.

## Inventory Ownership
- Merge platform-specific inventory sources in the data layer before presentation observes devices.
- Keep local inventory desktop-only and cloud inventory auth-owned.
- Cloud logout, cloud refresh failure, or cloud socket failure must not remove the desktop local inventory source.
- Web and mobile paths remain cloud-only and must not create local placeholders.
- On desktop, pin the synthetic/merged local device first. Order every remaining visible inventory oldest-first by `createdAt`, with stable device-id ties and missing timestamps after timestamped records. Web/mobile have no local row and are fully chronological. Reapply this invariant after authoritative fetches, live mutations/status events, and local/cloud merging rather than trusting source order.
- `DeviceCubit` is the sole presentation authority for the active conversation device; settings inspection state must not replace it implicitly.

## Selection and Restore
- Persist active device identity independently from the currently loaded device configuration.
- Persist provider and model route preferences as one stable device-scoped pair; do not hydrate one field from an unrelated preference namespace.
- During cold start, preserve a persisted cloud identity while cloud inventory is pending; never temporarily fall back to the local device.
- Treat a successful cloud inventory response as authoritative for cloud-device membership. Clear a missing persisted cloud id before publishing the merged inventory so presentation can choose a valid fallback.
- Do not clear the local-device identity merely because the local daemon is temporarily unreachable; cloud inventory does not own local membership.
- Clear user-scoped cloud inventory and active cloud selection on logout while preserving any valid local source.

## Account-Owned Mutations

- Device renames must pass through `DeviceCubit` and `IDeviceRepository`, wait for the correlated authoritative gateway response, and update presentation through the inventory stream.
- A merged local/cloud device must target its `cloudDeviceId` for account mutations; never send the synthetic `local-agent` id to the backend.
- Do not expose account-owned rename controls for a local-only device without a cloud identity.
- The Add Device flow may hold the creation-only pairing token transiently only
  to build one installer command. It must never receive, display, copy, or
  persist the durable device token, and it must continue automatically when
  the authoritative inventory reports the created device online.

## Client and Transport Ownership
- Use `IDeviceClientRegistry` and `ManagedConversationClientRegistry` to preserve one managed client per device.
- Retain clients only for devices still present in merged inventory and dispose registries with their owning cubit/service.
- Device-targeted operations must resolve local versus cloud transport through `DeviceConnectionCoordinator`.
- Desktop daemon health, lifecycle, update, socket, and voice endpoints must derive from `AppConfig.localGatewayUrl`.
- Every desktop daemon HTTP/WebSocket request must use the credential belonging to the same active Sanad Home; non-desktop runtimes are remote-only.
- `ENABLE_CLOUD_GATEWAY=false` is development isolation: make local transport primary without changing production defaults.

## Local Daemon Control
- All daemon lifecycle operations must pass through `LocalDaemonController`; presentation must not branch on source-versus-standalone runtime details.
- Development source runtimes must not be force-terminated or auto-started by normal UI lifecycle actions.
- A failed or timed-out safe restart must not fall back to process termination or stop/start; force restart requires an explicit daemon request flag.
- Production service management remains encapsulated by the standalone controller implementation.
- An installed daemon owns its own updates through the local update endpoint. The client may bootstrap a verified agent only when the executable is absent; it must not maintain a competing updater after installation.

## Cross-Feature Boundary
- Device selection comes from `DeviceCubit`; conversation cache/session selection belongs to the conversations feature.
- A device switch must publish the device identity before device-scoped conversation data is refreshed.
- Device models may expose routing context, but conversation sessions must not depend on device runtime-type discriminators.
