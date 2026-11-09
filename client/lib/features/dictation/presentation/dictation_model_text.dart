/// The words the dictation surfaces show for one daemon row.
///
/// The daemon ships identity (`name`, or a `label_code` for a row it owns) and
/// closed-set codes (`badge`, readiness reasons); every sentence a user reads is
/// produced here, from the Client's own localization. Both the model sheet and
/// the device settings card go through this file so the two surfaces cannot
/// describe the same model differently.
library;

import 'package:sanad_client/l10n/app_localizations.dart';

/// The row title: the model's proper noun, or the localized identity of a row
/// the daemon owns.
///
/// It takes the three identity fields rather than a row type because the
/// settings projection and the live catalog row are different models of the same
/// wire fields, and both must render the same title.
String dictationModelTitle(
  AppLocalizations l10n, {
  required String id,
  String? name,
  String? labelCode,
}) {
  if (labelCode != null) {
    return switch (labelCode) {
      'path_override' => l10n.dictationPathOverrideModel,
      _ => name ?? labelCode,
    };
  }
  return name ?? id;
}

/// The localized badge for a closed-set badge code, or null for no badge.
String? dictationModelBadge(AppLocalizations l10n, String? badge) {
  return switch (badge) {
    'recommended' => l10n.dictationBadgeRecommended,
    'faster' => l10n.dictationBadgeFaster,
    'more_accurate' => l10n.dictationBadgeMoreAccurate,
    'custom' => l10n.dictationBadgeCustom,
    _ => null,
  };
}

/// Turns a daemon readiness code into user-facing copy.
///
/// The daemon reports codes, never sentences (it has no locale). An unknown code
/// falls back to a neutral sentence instead of being rendered verbatim, so a
/// parser or config message can never reach a surface.
String dictationReasonLabel(AppLocalizations l10n, String reason) {
  return switch (reason) {
    'native_runtime_preparing' => l10n.dictationRuntimePreparing,
    'native_runtime_missing' => l10n.dictationRuntimeMissing,
    'native_runtime_install_failed' => l10n.dictationRuntimeInstallFailed,
    'unsupported_platform' => l10n.dictationUnsupportedPlatform,
    'dictation_disabled' => l10n.dictationDisabled,
    'model_not_installed' => l10n.dictationModelNotInstalled,
    'sherpa_runtime_missing' => l10n.dictationSherpaRuntimeMissing,
    _ => l10n.dictationUnavailable,
  };
}

/// The localized sentence for a **channel** refusal, or null for any other code.
///
/// These are the codes the transport boundary raises before a single command
/// leaves the Client: a hosted device without the relay, a Gateway that refuses
/// the claim, a frame it read as malformed, or a build the Agent no longer
/// accepts. Nothing reached the daemon, so the catalog is still unknown and
/// empty — which is exactly why the model sheet must name this reason instead of
/// claiming no model is installed. Every other code (a readiness reason, a
/// session failure) has its own surface and returns null here.
String? dictationChannelRefusalLabel(AppLocalizations l10n, String? code) {
  return switch (code) {
    'dictation_unavailable' => l10n.dictationUnavailable,
    'relay_unavailable' => l10n.dictationRelayUnavailable,
    'relay_forbidden' => l10n.dictationRelayForbidden,
    'relay_invalid_request' => l10n.dictationRelayInvalidRequest,
    'update_required' => l10n.dictationUpdateRequired,
    _ => null,
  };
}
