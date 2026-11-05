---
title: "Experimental Realtime Voice"
description: "Current experimental Gemini Realtime voice path, transports, audio format, interruption behavior, and release boundaries."
---

# Experimental Realtime Voice

> [!WARNING]
> Realtime voice is experimental and hidden by default. The current
> `AgentCapabilities` surface does not advertise `voice_call`, so voice is not
> part of the stable Sanad feature set.

Sanad contains a realtime duplex voice implementation built around Gemini
Realtime. The path is retained for development and validation while text
conversations remain the supported default.

> Dictation (speech → text in the composer) is a separate, local-only feature:
> see [Local Dictation](local_dictation.md).

## Components

The experimental path consists of:

- microphone capture and PCM playback in the Flutter client;
- `VoiceStreamCubit` for session state, local/cloud routing, mute, stop, and
  interruption behavior;
- `VoiceTransportChannel` implementations for a direct local WebSocket and the
  optional hosted Socket.IO relay;
- `GeminiRealtimeVoiceProvider` for the realtime model connection;
- `VoiceEngine` for transport/provider coordination and conversation-event
  persistence.

## Routing

### Local device

For an agent on the same desktop computer, the client derives the daemon origin
from `AppConfig.localGatewayUrl` and opens the voice WebSocket. The endpoint
must remain worktree-aware during development and must not assume a fixed
port.

### Remote device

For a paired remote agent, the client uses the authenticated hosted socket.
Audio and control events are relayed to the selected device. This path requires
the optional hosted service and a compatible Gemini Realtime configuration on
the device.

## Audio and events

The client captures mono PCM input and plays PCM output produced by the
provider. Control events communicate voice text responses, user
transcriptions, interruption acknowledgements, and session state.

Voice-generated conversation entries retain the same session identity and
persistence boundary as text conversation events.

### Audio contract

The current implementation uses raw signed PCM:

| Direction | Format |
| --- | --- |
| Client microphone → agent/provider | 16 kHz, mono, 16-bit little-endian PCM |
| Provider/agent → client speaker | 24 kHz, mono, 16-bit little-endian PCM |

Local transport sends audio as binary WebSocket frames. The hosted transport
relays byte arrays and accepts base64 as a compatibility fallback. Control and
transcription messages remain structured events rather than being mixed into
the PCM stream.

The client converts 24 kHz signed samples to its playback stream and keeps
playback buffering bounded. Microphone mute stops forwarding new chunks
without changing the text-session state.

### Local transport contract

The local client upgrades the daemon endpoint:

```text
/ws?type=voice&session_id=<session>&device_id=<device>
```

The endpoint origin comes from `AppConfig.localGatewayUrl`, including a
worktree-specific port during development. Binary client frames are microphone
audio. JSON client frames carry controls such as `interrupt`. Agent-to-client
binary frames are speaker audio; structured `device_event` frames carry
transcription and state events.

### Hosted relay contract

For a remote device, the client sends `start_voice` and `stop_voice` device
commands and forwards microphone data through `voice_audio_chunk`. The agent
receives relayed audio through `voice_audio_chunk_relay` and returns output
through `device_voice_audio_chunk`. `voice_control_relay` and `device_event`
carry interruption and transcription controls.

Every relay message must retain the selected device and session identity. A
client must not route voice data to whichever remote device happens to be
online.

### Session lifecycle

The client state moves through connecting, listening, speaking, error, and
stopped states. Starting a new voice session first closes an existing one.
Stopping cancels recording and playback subscriptions, closes the local
WebSocket or sends the remote stop command, and clears the voice-only state.

Transcriptions are persisted before the voice engine closes. Transport cleanup
must be idempotent because disconnect, explicit stop, and provider failure can
converge on the same close path.

## Barge-in

When speech activity is detected while output is playing, the client can:

1. clear pending playback;
2. send an interruption control event;
3. stop the current provider response;
4. return the voice session to listening state.

Interruption is isolated from the normal text runtime. A voice transport
failure must not terminate text conversations or the daemon event loop.

The current client also keeps a short pre-trigger microphone buffer so the
beginning of detected speech is not discarded. Voice activity detection uses
RMS energy and a hangover window to avoid sending continuous background audio.
These thresholds are implementation values, not a public compatibility
contract, and require device-level tuning.

Manual interruption clears queued speaker playback immediately and sends an
`interrupt` control through the active local or hosted route. The provider
acknowledges the cancellation with `voice_interrupted`, after which the client
returns to listening.

## Failure behavior

- A microphone or playback initialization failure moves the voice surface to
  an error state and closes partially opened resources.
- A local WebSocket error stops the experimental voice session; it does not
  stop the daemon.
- A disconnected hosted socket must not accept output as successfully sent.
- Provider failure closes the voice engine and preserves any pending
  transcription that can be committed safely.
- Reconnect and resume behavior is not yet a stable voice contract; callers
  should start a new voice session after a transport break.

## Current limitations

- Voice is not announced by the stable capabilities handshake.
- The flow depends on Gemini Realtime credentials and model availability.
- Cloud voice depends on the hosted relay.
- Recorded voice messages and composer audio attachments are not completed
  workflows.
- Platform permissions, hardware behavior, reconnect, quota handling, and
  release packaging still require end-to-end verification.

Voice may be promoted from experimental only after capability advertisement,
supported-platform testing, privacy review, and release validation are
complete.
