import 'package:uuid/uuid.dart';

/// Collision-resistant dictation transport identity.
///
/// One generator mints the identity for both channels: the local socket carries
/// it as `session_id`, the hosted channel as `dictation_id` and `request_id`
/// (§1 of `docs/technical/dictation_transport_protocol.md`). The Gateway's
/// admission and routing machinery treats it as authority, so a timestamp or a
/// counter — the previous local implementation — is not a valid identity.
class DictationIdentity {
  const DictationIdentity._();

  static const Uuid _uuid = Uuid();

  /// A fresh opaque identity matching the wire character class.
  static String next() => 'dict-${_uuid.v4()}';

  /// A fresh identity for the realtime voice session (§10.1).
  ///
  /// Same generator and character class as [next], different prefix, so the two
  /// identity families stay distinguishable in diagnostics.
  static String nextVoice() => 'voice-${_uuid.v4()}';

  /// True for a value the contract accepts as an identity.
  static bool isValid(String? value) {
    if (value == null || value.isEmpty || value.length > 128) return false;
    return RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);
  }
}
