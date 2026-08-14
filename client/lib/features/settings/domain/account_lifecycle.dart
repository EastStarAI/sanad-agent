enum AccountPresenceStatus { online, offline, unavailable }

enum AccountPrincipalKind { clientSession, agentDevice }

class AccountPrincipal {
  const AccountPrincipal({
    required this.kind,
    required this.id,
    required this.status,
    required this.isCurrent,
    required this.metadata,
    this.name,
    this.createdAt,
    this.lastActiveAt,
  });

  final AccountPrincipalKind kind;
  final String id;
  final AccountPresenceStatus status;
  final bool isCurrent;
  final Map<String, String?> metadata;
  final String? name;
  final DateTime? createdAt;
  final DateTime? lastActiveAt;

  factory AccountPrincipal.fromJson(Map<String, dynamic> json) {
    final kind = switch (json['kind']) {
      'client_session' => AccountPrincipalKind.clientSession,
      'agent_device' => AccountPrincipalKind.agentDevice,
      _ => throw const FormatException('Unsupported account principal.'),
    };
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) throw const FormatException('Missing account principal identity.');
    final rawMetadata = json['metadata'];
    return AccountPrincipal(
      kind: kind,
      id: id,
      status: switch (json['status']) {
        'online' => AccountPresenceStatus.online,
        'offline' => AccountPresenceStatus.offline,
        _ => AccountPresenceStatus.unavailable,
      },
      isCurrent: json['is_current'] == true,
      name: json['name']?.toString(),
      metadata: rawMetadata is Map
          ? rawMetadata.map((key, value) => MapEntry(key.toString(), value?.toString()))
          : const {},
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      lastActiveAt: DateTime.tryParse(json['last_active_at']?.toString() ?? ''),
    );
  }
}

class AccountLifecycleSnapshot {
  const AccountLifecycleSnapshot({
    required this.items,
    required this.presenceAvailable,
  });

  final List<AccountPrincipal> items;
  final bool presenceAvailable;

  List<AccountPrincipal> get clientSessions =>
      items.where((item) => item.kind == AccountPrincipalKind.clientSession).toList(growable: false);

  AccountPrincipal? agent(String deviceId) {
    for (final item in items) {
      if (item.kind == AccountPrincipalKind.agentDevice && item.id == deviceId) return item;
    }
    return null;
  }
}

class AccountRevokeResult {
  const AccountRevokeResult({
    required this.requestId,
    required this.currentSessionRevoked,
  });

  final String requestId;
  final bool currentSessionRevoked;
}

class AccountLifecycleException implements Exception {
  const AccountLifecycleException(this.message, {this.outcomeUnknown = false});

  final String message;
  final bool outcomeUnknown;

  @override
  String toString() => message;
}
