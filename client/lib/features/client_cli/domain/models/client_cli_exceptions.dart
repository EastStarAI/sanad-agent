class ClientCliException implements Exception {
  final String code;
  final String message;

  const ClientCliException(this.code, this.message);

  @override
  String toString() => 'ClientCliException($code): $message';
}

class ClientCliNoOwnerException extends ClientCliException {
  ClientCliNoOwnerException(String sanadHome)
      : super(
          'no_owner',
          'No active Sanad Client found for Sanad Home: $sanadHome. '
          'Ensure Sanad Client is running and Client CLI is enabled.',
        );
}

class ClientCliDisabledException extends ClientCliException {
  ClientCliDisabledException(String sanadHome)
      : super(
          'disabled',
          'Client CLI is disabled in Sanad Client settings for Sanad Home: $sanadHome. '
          'Enable it in Settings -> General -> Client CLI.',
        );
}

class ClientCliAmbiguousOwnerException extends ClientCliException {
  ClientCliAmbiguousOwnerException(String sanadHome, [String? detail])
      : super(
          'ambiguous',
          'Multiple or conflicting Sanad Client instances detected for Sanad Home: $sanadHome.'
          '${detail != null ? ' ($detail)' : ''}',
        );
}

class ClientCliVersionMismatchException extends ClientCliException {
  ClientCliVersionMismatchException({
    required String clientVersion,
    required String cliVersion,
  }) : super(
          'version_mismatch',
          'Sanad Client version mismatch. Running client version is "$clientVersion", '
          'but command version is "$cliVersion".',
        );
}

class ClientCliSecurityException extends ClientCliException {
  ClientCliSecurityException(String reason)
      : super('security_violation', 'Security validation failed: $reason');
}
