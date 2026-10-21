import 'dart:convert';

import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/cached_workspace_section.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_section_page.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';

/// Versioned JSON codec for [DeviceConversationCacheSnapshot].
///
/// The persisted blob carries a [schemaVersion]. On load, if the version is
/// newer than the one the running client understands, the blob is invalidated
/// (treated as empty) rather than crashing. Forward-only migrations can be
/// added here as the schema evolves.
class ConversationCacheCodec {
  static const int schemaVersion = 4;
  static const int maxPersistedSessionsPerSection = 50;

  const ConversationCacheCodec();

  String encode(DeviceConversationCacheSnapshot snapshot) {
    return jsonEncode(_snapshotToJson(snapshot));
  }

  DeviceConversationCacheSnapshot decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return DeviceConversationCacheSnapshot.empty();
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final version = (json['v'] as num?)?.toInt() ?? 0;
      if (version > schemaVersion) {
        // Unknown future schema: invalidate safely.
        return DeviceConversationCacheSnapshot.empty();
      }
      return _snapshotFromJson(json);
    } catch (_) {
      // Corrupt payload: invalidate safely.
      return DeviceConversationCacheSnapshot.empty();
    }
  }

  // ---------------------------------------------------------------------------
  // Snapshot
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _snapshotToJson(DeviceConversationCacheSnapshot s) {
    return {
      'v': schemaVersion,
      'activeDeviceId': s.activeDeviceId,
      'contexts': {
        for (final entry in s.contexts.entries) entry.key: _contextToJson(entry.value),
      },
      'sessionDrafts': {
        for (final entry in s.sessionDrafts.entries) entry.key: _draftToJson(entry.value),
      },
      'sessionViewportAnchors': s.sessionViewportAnchors,
    };
  }

  DeviceConversationCacheSnapshot _snapshotFromJson(Map<String, dynamic> json) {
    final activeDeviceId = json['activeDeviceId'] as String?;
    final contextsRaw = (json['contexts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final draftsRaw = (json['sessionDrafts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final viewportAnchorsRaw = (json['sessionViewportAnchors'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DeviceConversationCacheSnapshot(
      activeDeviceId: activeDeviceId,
      contexts: {
        for (final entry in contextsRaw.entries)
          entry.key: _contextFromJson(
            entry.value as Map<String, dynamic>,
            deviceId: entry.key,
          ),
      },
      sessionDrafts: {
        for (final entry in draftsRaw.entries) entry.key: _draftFromJson(entry.value as Map<String, dynamic>),
      },
      sessionViewportAnchors: {
        for (final entry in viewportAnchorsRaw.entries)
          if (entry.value is String && (entry.value as String).trim().isNotEmpty)
            entry.key: (entry.value as String).trim(),
      },
    );
  }

  // ---------------------------------------------------------------------------
  // DeviceConversationContext
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _contextToJson(DeviceConversationContext c) {
    return {
      'lastDestination': _destinationToJson(c.lastDestination),
      'lastSelectedSessionId': c.lastSelectedSessionId,
      'workspaces': _workspaceSectionToJson(c.workspaces),
      'unscoped': _pageToJson(c.unscopedConversations),
      'workspacePages': {
        for (final entry in c.workspaceConversationPages.entries) entry.key: _pageToJson(entry.value),
      },
      'expansion': c.workspaceExpansion,
      'newDraft': {
        'text': c.newConversationDraftText,
        'workspaceId': c.newConversationDraftWorkspaceId,
        'providerId': c.newConversationDraftProviderId,
        'model': c.newConversationDraftModel,
        'thinkingMode': c.newConversationDraftThinkingMode,
        'permissionMode': c.newConversationDraftPermissionMode,
        'pendingRequestId': c.newConversationDraftPendingRequestId,
        'updatedAt': c.newConversationDraftUpdatedAt.toIso8601String(),
      },
    };
  }

  DeviceConversationContext _contextFromJson(
    Map<String, dynamic> json, {
    required String deviceId,
  }) {
    final pagesRaw = (json['workspacePages'] as Map?)?.cast<String, dynamic>() ?? const {};
    final newDraft = (json['newDraft'] as Map?)?.cast<String, dynamic>() ?? const {};
    final newDraftRoute = _DraftRoute.fromJson(newDraft);
    return DeviceConversationContext(
      lastDestination: _destinationFromJson(json['lastDestination'], deviceId),
      lastSelectedSessionId: json['lastSelectedSessionId'] as String?,
      workspaces: _workspaceSectionFromJson(
        (json['workspaces'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      unscopedConversations: _pageFromJson(
        (json['unscoped'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      workspaceConversationPages: {
        for (final entry in pagesRaw.entries) entry.key: _pageFromJson(entry.value as Map<String, dynamic>),
      },
      workspaceExpansion: ((json['expansion'] as Map?)?.cast<String, dynamic>() ?? const {}).map(
        (k, v) => MapEntry(k, v == true),
      ),
      newConversationDraftText: (newDraft['text'] as String?) ?? '',
      newConversationDraftWorkspaceId: newDraft['workspaceId'] as String?,
      newConversationDraftProviderId: newDraftRoute.providerId,
      newConversationDraftModel: newDraftRoute.model,
      newConversationDraftThinkingMode: newDraftRoute.thinkingMode,
      newConversationDraftPermissionMode: newDraft['permissionMode'] as String?,
      newConversationDraftPendingRequestId: newDraft['pendingRequestId'] as String?,
      newConversationDraftUpdatedAt:
          _parseDate(newDraft['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, dynamic>? _destinationToJson(
    ConversationDestination? destination,
  ) {
    if (destination == null || destination.isConversationsList) return null;
    return {
      'kind': destination.kind.name,
      if (destination.sessionId != null) 'sessionId': destination.sessionId,
      if (destination.workspaceId != null) 'workspaceId': destination.workspaceId,
    };
  }

  ConversationDestination? _destinationFromJson(Object? raw, String deviceId) {
    if (raw is! Map) return null;
    final json = raw.cast<String, dynamic>();
    switch (json['kind']) {
      case 'session':
        final sessionId = (json['sessionId'] as String?)?.trim();
        if (sessionId == null || sessionId.isEmpty) return null;
        return ConversationDestination.session(
          deviceId: deviceId,
          sessionId: sessionId,
        );
      case 'newConversation':
        final workspaceId = (json['workspaceId'] as String?)?.trim();
        return ConversationDestination.newConversation(
          deviceId: deviceId,
          workspaceId: workspaceId == null || workspaceId.isEmpty ? null : workspaceId,
        );
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Workspace section
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _workspaceSectionToJson(CachedWorkspaceSection s) {
    return {
      'workspaces': [for (final w in s.workspaces) _workspaceToJson(w)],
      'state': s.state.name,
      'lastRefreshedAt': s.lastRefreshedAt?.toIso8601String(),
      'lastErrorAt': s.lastErrorAt?.toIso8601String(),
      'lastError': s.lastError,
    };
  }

  CachedWorkspaceSection _workspaceSectionFromJson(Map<String, dynamic> json) {
    final rawList = (json['workspaces'] as List?) ?? const [];
    return CachedWorkspaceSection(
      workspaces: [
        for (final raw in rawList) _workspaceFromJson(Map<String, dynamic>.from(raw as Map)),
      ],
      state: _stateFromName(
        json['state'] as String?,
        hasSnapshot: rawList.isNotEmpty,
      ),
      lastRefreshedAt: _parseDate(json['lastRefreshedAt']),
      lastErrorAt: _parseDate(json['lastErrorAt']),
      lastError: json['lastError'] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // Conversation section page
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _pageToJson(ConversationSectionPage p) {
    return {
      'sessions': [
        for (final s in p.sessions.take(maxPersistedSessionsPerSection)) _sessionToJson(s),
      ],
      'nextCursor': p.sessions.length > maxPersistedSessionsPerSection ? null : p.nextCursor,
      'hasMore': p.sessions.length > maxPersistedSessionsPerSection || p.hasMore,
      'state': p.state.name,
      'lastRefreshedAt': p.lastRefreshedAt?.toIso8601String(),
      'lastErrorAt': p.lastErrorAt?.toIso8601String(),
      'lastError': p.lastError,
    };
  }

  ConversationSectionPage _pageFromJson(Map<String, dynamic> json) {
    final rawList = (json['sessions'] as List?) ?? const [];
    return ConversationSectionPage(
      sessions: [
        for (final raw in rawList) _sessionFromJson(Map<String, dynamic>.from(raw as Map)),
      ],
      nextCursor: json['nextCursor'] as String?,
      hasMore: (json['hasMore'] as bool?) ?? false,
      state: _stateFromName(
        json['state'] as String?,
        hasSnapshot: rawList.isNotEmpty,
      ),
      lastRefreshedAt: _parseDate(json['lastRefreshedAt']),
      lastErrorAt: _parseDate(json['lastErrorAt']),
      lastError: json['lastError'] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // Workspace, session, draft
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _workspaceToJson(DeviceWorkspace w) => {
    'id': w.id,
    'name': w.name,
    'path': w.path,
    'trustState': w.trustState,
    'availability': w.availability,
  };

  DeviceWorkspace _workspaceFromJson(Map<String, dynamic> json) => DeviceWorkspace(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    path: (json['path'] ?? '').toString(),
    trustState: (json['trustState'] ?? 'untrusted').toString(),
    availability: (json['availability'] ?? 'available').toString(),
  );

  Map<String, dynamic> _sessionToJson(Session s) => {
    'id': s.id,
    'title': s.title,
    'device_id': s.deviceId,
    'created_at': s.createdAt.toIso8601String(),
    'updated_at': s.updatedAt.toIso8601String(),
    'last_user_message_at': s.lastMessageAt?.toIso8601String(),
    'model': s.model,
    'model_display': s.modelDisplay,
    'provider_instance_id': s.modelProvider,
    'route_revision': s.routeRevision,
    'history_revision': s.historyRevision,
    'thinking_mode': s.thinkingMode,
    'reasoning_level': s.reasoningLevel,
    'context_tokens': s.contextTokens,
    'workspace_id': s.workspaceId,
    'workspace_name': s.workspaceName,
    'workspace_path': s.workspacePath,
    'workspace_trust_state': s.workspaceTrustState,
    'metadata': s.metadata,
  };

  /// Decodes a cached session through the canonical wire contract. Caches
  /// written before Task 122 stored the provider as `model_provider`, which
  /// [Session.fromJson] does not read; migrate it so the route survives.
  Session _sessionFromJson(Map<String, dynamic> json) {
    final legacyProvider = json['model_provider'];
    if (json['provider_instance_id'] == null && legacyProvider != null) {
      json = {...json, 'provider_instance_id': legacyProvider};
    }
    return Session.fromJson(json);
  }

  Map<String, dynamic> _draftToJson(ConversationDraft d) => {
    'text': d.text,
    'workspaceId': d.workspaceId,
    'providerId': d.providerId,
    'model': d.model,
    'thinkingMode': d.thinkingMode,
    'permissionMode': d.permissionMode,
    'pendingRequestId': d.pendingRequestId,
    'appliedStopRecoveryIds': d.appliedStopRecoveryIds.toList(growable: false),
    'pendingStopRecoveryIds': d.pendingStopRecoveryIds.toList(growable: false),
    'stopRecoveryClaimIds': d.stopRecoveryClaimIds,
    'stopRecoveryOwnerTokens': d.stopRecoveryOwnerTokens,
    'updatedAt': d.updatedAt.toIso8601String(),
  };

  ConversationDraft _draftFromJson(Map<String, dynamic> json) {
    final route = _DraftRoute.fromJson(json);
    return ConversationDraft(
      text: (json['text'] as String?) ?? '',
      workspaceId: json['workspaceId'] as String?,
      providerId: route.providerId,
      model: route.model,
      thinkingMode: route.thinkingMode,
      permissionMode: json['permissionMode'] as String?,
      pendingRequestId: json['pendingRequestId'] as String?,
      appliedStopRecoveryIds: (json['appliedStopRecoveryIds'] as List? ?? const [])
          .map((value) => value.toString())
          .toSet(),
      pendingStopRecoveryIds: (json['pendingStopRecoveryIds'] as List? ?? const [])
          .map((value) => value.toString())
          .toSet(),
      stopRecoveryClaimIds: (json['stopRecoveryClaimIds'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      stopRecoveryOwnerTokens: (json['stopRecoveryOwnerTokens'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      updatedAt: _parseDate(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  ConversationResourceState _stateFromName(
    String? name, {
    required bool hasSnapshot,
  }) {
    switch (name) {
      case 'loading':
      case 'refreshing':
        return hasSnapshot ? ConversationResourceState.ready : ConversationResourceState.notLoaded;
      case 'ready':
        return ConversationResourceState.ready;
      case 'staleError':
        return ConversationResourceState.staleError;
      case 'notLoaded':
      default:
        return ConversationResourceState.notLoaded;
    }
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null || value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }
}

/// Persisted draft route healed on load: provider, model and thinking restore
/// only as one complete provider+model route. A half route persisted by an
/// older client (model without provider) is dropped so the device route or
/// readiness default applies instead of an unsendable provider-less route.
class _DraftRoute {
  final String? providerId;
  final String? model;
  final String? thinkingMode;

  const _DraftRoute._(this.providerId, this.model, this.thinkingMode);

  factory _DraftRoute.fromJson(Map<String, dynamic> json) {
    final providerId = json['providerId'] as String?;
    final model = json['model'] as String?;
    if (!ConversationDraft.isCompleteRoute(providerId, model)) {
      return const _DraftRoute._(null, null, null);
    }
    return _DraftRoute._(providerId, model, json['thinkingMode'] as String?);
  }
}
