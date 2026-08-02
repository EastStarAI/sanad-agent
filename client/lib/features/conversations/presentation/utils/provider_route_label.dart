import 'package:sanad_client/features/conversations/domain/models/session.dart';

String? resolveProviderDisplayName({
  required Session? session,
  required String? providerId,
  required Map<String, String> providerDisplayNames,
}) {
  final normalizedProviderId = providerId?.trim();
  if (normalizedProviderId == null || normalizedProviderId.isEmpty) {
    return null;
  }

  if (_sessionMetadataMatchesProvider(session, normalizedProviderId)) {
    final metadataDisplayName = session?.metadata?['provider_display_name']
        ?.toString()
        .trim();
    if (metadataDisplayName != null && metadataDisplayName.isNotEmpty) {
      return metadataDisplayName;
    }

    final metadataDisplayFallback = session?.metadata?['provider_display']
        ?.toString()
        .trim();
    if (metadataDisplayFallback != null && metadataDisplayFallback.isNotEmpty) {
      return metadataDisplayFallback;
    }
  }

  final mapped = providerDisplayNames[normalizedProviderId];
  if (mapped != null && mapped.trim().isNotEmpty) {
    return mapped.trim();
  }

  if (_looksLikeUuid(normalizedProviderId)) {
    return null;
  }

  return normalizedProviderId
      .replaceAll('_', '-')
      .split('-')
      .where((part) => part.isNotEmpty)
      .map(
        (part) => part.length == 1
            ? part.toUpperCase()
            : '${part[0].toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

bool _sessionMetadataMatchesProvider(Session? session, String providerId) {
  final sessionProviderId = session?.modelProvider?.trim();
  if (sessionProviderId != null && sessionProviderId.isNotEmpty) {
    return sessionProviderId == providerId;
  }

  final metadataProviderId =
      session?.metadata?['provider_instance_id']?.toString().trim() ??
      session?.metadata?['provider']?.toString().trim() ??
      session?.metadata?['model_provider']?.toString().trim();
  return metadataProviderId == providerId;
}

bool _looksLikeUuid(String value) {
  final parts = value.split('-');
  const expectedLengths = [8, 4, 4, 4, 12];
  if (parts.length != expectedLengths.length) return false;

  for (var i = 0; i < expectedLengths.length; i++) {
    final part = parts[i];
    if (part.length != expectedLengths[i]) return false;
    for (final codeUnit in part.codeUnits) {
      final isDigit = codeUnit >= 48 && codeUnit <= 57;
      final isUpperHex = codeUnit >= 65 && codeUnit <= 70;
      final isLowerHex = codeUnit >= 97 && codeUnit <= 102;
      if (!isDigit && !isUpperHex && !isLowerHex) return false;
    }
  }

  return true;
}
