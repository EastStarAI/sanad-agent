/// Wire projection of the local dictation runtime.
///
/// The two payloads the Client reads — `stt_status` and the settings page's
/// `dictation` block — are built here, from the same inputs, so a surface can
/// never describe a state the other one does not. They carry identity and facts
/// only: a model's own name, its locale description map, closed-set codes, and
/// install state.
///
/// It lives outside `DictationService` because it is a pure function of the
/// catalog, the store, and readiness: nothing here starts, stops, or loads
/// anything.
library;

import 'stt_catalog.dart';
import 'stt_model_store.dart';
import 'stt_settings.dart';
import 'stt_types.dart';

/// `stt_status` payload: readiness, the selected model, and the catalog rows.
Map<String, dynamic> dictationStatusPayload({
  required SttReadiness readiness,
  required SttSettings settings,
  required SttModelStore store,
  required SttEngineAvailability availability,
  required String? selectedModelId,
  required bool busy,
  required bool hasOverridePath,
  required bool overrideReady,
}) {
  return {
    'supported': readiness.isSupported,
    'ready': readiness.isReady,
    if (readiness.reason != null) 'reason': readiness.reason,
    'busy': busy,
    'selected': selectedModelId,
    // Host filesystem layout is never part of a status payload. A local or
    // hosted reader only needs to know that an override exists.
    'has_model_path': hasOverridePath,
    'models': dictationModelRows(
      settings: settings,
      store: store,
      availability: availability,
      hasOverridePath: hasOverridePath,
      overrideReady: overrideReady,
    ),
  };
}

/// Device settings projection of the dictation runtime.
///
/// It reuses the same catalog rows and readiness as `stt_status` so the settings
/// page can never describe a different state than the mic.
Map<String, dynamic> dictationSettingsPayload({
  required SttReadiness readiness,
  required SttSettings settings,
  required SttModelStore store,
  required SttEngineAvailability availability,
  required String? selectedModelId,
  required bool busy,
  required bool hasOverridePath,
  required bool overrideReady,
}) {
  return {
    'enabled': settings.enabled,
    'managed_externally': settings.enabledManagedByConfig,
    'selected_model_id': selectedModelId,
    'supported': readiness.isSupported,
    'ready': readiness.isReady,
    if (readiness.reason != null) 'reason': readiness.reason,
    'busy': busy,
    'has_model_path': hasOverridePath,
    'models': dictationModelRows(
      settings: settings,
      store: store,
      availability: availability,
      hasOverridePath: hasOverridePath,
      overrideReady: overrideReady,
    ),
  };
}

/// Catalog rows as the Client renders them.
///
/// A row carries identity and facts, never sentences: `name` is the model's own
/// proper noun, `description` is the one locale map the daemon is allowed to ship
/// (it belongs to the model, not to the surface), and `badge` is a code from a
/// closed set the Client localizes. A daemon-owned row that is not a model — the
/// `stt.model_path` override — carries `label_code` instead.
List<Map<String, dynamic>> dictationModelRows({
  required SttSettings settings,
  required SttModelStore store,
  required SttEngineAvailability availability,
  required bool hasOverridePath,
  required bool overrideReady,
}) {
  return [
    // An explicit `stt.model_path` is a ready model even though it is not a
    // catalog entry; without this row the UI offers the setup sheet.
    if (hasOverridePath)
      {
        'id': 'path-override',
        'label_code': 'path_override',
        'badge': SttModelBadge.custom.code,
        // The absolute override path never leaves this machine: the row's
        // identity is enough for every surface to describe it.
        'streaming': false,
        'location': SttModelLocation.local.name,
        'language': settings.language,
        'size_bytes': 0,
        'hosted': false,
        'installed': overrideReady,
        'engine': SttEngineKind.whisperCpp.name,
      },
    for (final entry in usableSttEntries(availability))
      if (!entry.hidden)
        {
          'id': entry.id,
          'name': entry.name,
          'description': Map<String, String>.unmodifiable(entry.description),
          if (entry.badge != SttModelBadge.none) 'badge': entry.badge.code,
          'speed_tier': entry.speedTier,
          'streaming': entry.mode == SttModelMode.streaming,
          'location': entry.location.name,
          'language': entry.language,
          'size_bytes': entry.totalBytes,
          'hosted': entry.hosted,
          'installed': store.statusOf(entry).installed,
          'engine': entry.engine.name,
        },
  ];
}
