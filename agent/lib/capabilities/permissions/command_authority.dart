import 'dart:async';

/// Daemon-derived authority of the transport that delivered a command or turn.
///
/// Authority comes from the receiving transport, never from payload content.
/// Every authenticated client transport acts for the device owner: the
/// authenticated loopback Local Gateway, the authenticated Cloud Gateway relay
/// (user decision 2026-10-21: the cloud client is as trusted as the local
/// client), and the in-process CLI. Any other or unauthenticated transport is
/// [unverified] and fails closed. Ingress always overwrites the reserved
/// payload field: a sender may request [unverified] for itself, never [owner].
enum CommandAuthority {
  owner('owner'),
  unverified('unverified');

  const CommandAuthority(this.value);

  final String value;

  /// Reserved field stamped by transport ingress on command payloads and
  /// carried into turn metadata.
  static const payloadKey = 'command_authority';

  /// Turn metadata keys that grant or describe approval authority. Only an
  /// owner turn may carry them.
  static const turnAuthorityKeys = {'allow_all_tools', 'permission_mode'};

  static const _zoneKey = #sanadCommandAuthority;

  bool get isOwner => this == CommandAuthority.owner;

  /// Reads a daemon-stamped value; anything else is [unverified].
  static CommandAuthority fromStamped(Object? value) =>
      value == CommandAuthority.owner.value
      ? CommandAuthority.owner
      : CommandAuthority.unverified;

  /// Authority of in-process callers on this zone. Code outside any relay
  /// zone runs as the operating-system user that owns this Agent.
  static CommandAuthority get current {
    final value = Zone.current[_zoneKey];
    return value is CommandAuthority ? value : CommandAuthority.owner;
  }

  /// Runs [body] with [authority] as the in-process authority. A nested call
  /// can only keep or lower the surrounding authority.
  static R runAs<R>(CommandAuthority authority, R Function() body) {
    final effective = current == CommandAuthority.unverified
        ? CommandAuthority.unverified
        : authority;
    return runZoned(body, zoneValues: {_zoneKey: effective});
  }

  /// Stamps [payload] received on a transport with [ingress] authority. An
  /// owner transport honours a sender's request for [unverified]; an
  /// unverified transport always stamps [unverified].
  static Map<String, dynamic> stampIngress(
    Map<String, dynamic> payload,
    CommandAuthority ingress,
  ) {
    final lowered = payload[payloadKey] == CommandAuthority.unverified.value;
    final authority = ingress.isOwner && !lowered
        ? CommandAuthority.owner
        : CommandAuthority.unverified;
    return {...payload, payloadKey: authority.value};
  }

  /// Normalizes turn [metadata] for [authority]: drops any sender-written
  /// authority, removes approval-authority keys unless owner, and records the
  /// effective authority.
  static Map<String, dynamic> stampTurnMetadata(
    Map<String, dynamic> metadata,
    CommandAuthority authority,
  ) {
    final result = Map<String, dynamic>.from(metadata)..remove(payloadKey);
    if (!authority.isOwner) {
      result.removeWhere((key, _) => turnAuthorityKeys.contains(key));
    }
    result[payloadKey] = authority.value;
    return result;
  }
}
