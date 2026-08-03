# Voice Feature Contract

## Scope
This contract applies to `client/lib/features/voice/`.

## Runtime Ownership
- `VoiceStreamCubit` owns voice-session lifecycle, mute state, interruption, transport resolution, and error projection.
- Resolve local versus cloud voice routing through `DeviceConnectionCoordinator`; presentation must not open or select sockets directly.
- Keep local voice endpoints derived from `AppConfig.localGatewayUrl`.
- Local voice is desktop-only and uses the same active-Home Local Gateway credential as command and lifecycle transports; never place the credential in the voice URL.
- Validate runtime/device capability and credit readiness before starting a voice session.

## Audio and Interruption
- Preserve the runtime audio format expected by the agent across capture, transport, and playback.
- Barge-in must signal interruption through the owning runtime path and clear buffered playback immediately.
- Muted input must not transmit captured audio.

## Presentation
- Voice widgets observe cubit state and emit user intent only.
- Keep visualizer rendering independent from socket, repository, and device lifecycle state.
- Do not duplicate voice-session state in widgets or app-global presentation stores.
- Architecture and audio-pipeline design belong in `docs/technical/voice_streaming.md`, not this contract.
