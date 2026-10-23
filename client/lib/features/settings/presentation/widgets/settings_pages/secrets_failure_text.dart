import 'package:sanad_client/features/settings/data/secrets_client.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Localized copy for one typed secret failure (Task 140 C3, C4).
///
/// The mapping is deliberately total over [SecretsErrorCode]: the Agent's own
/// error `message` is operator copy and never becomes UI text, so a code this
/// Client does not know returns `null` and the caller renders its own generic
/// sentence instead of guessing. No branch can carry a submitted value: the
/// input is an enum.
String? secretsFailureText(AppLocalizations l10n, SecretsErrorCode code) {
  return switch (code) {
    SecretsErrorCode.permissionDenied => l10n.secretsPermissionDenied,
    SecretsErrorCode.invalidRequest => l10n.secretsInvalidRequest,
    SecretsErrorCode.invalidSecretName => l10n.secretInvalidName,
    SecretsErrorCode.reservedSecretName => l10n.secretReservedName,
    SecretsErrorCode.invalidSecretValue => l10n.secretValueInvalid,
    SecretsErrorCode.vaultUnavailable => l10n.secretsVaultUnavailable,
    SecretsErrorCode.internalError => l10n.secretsInternalError,
    SecretsErrorCode.deviceUnavailable => l10n.secretsUnavailable,
    SecretsErrorCode.unknown => null,
  };
}
