import 'package:logging/logging.dart';

import '../../core/config.dart';
import '../../core/di.dart';
import '../db/session_db.dart';
import '../models/session_state.dart';
import '../session_manager.dart';
import 'schedule_model.dart';

/// The only owner that creates a schedule's conversation (Task 139 A4).
///
/// Session creation goes through the existing `SessionManager.createSession`
/// path and the same workspace assignment `create_session` already performs;
/// there is no second creation path, and title generation is never touched —
/// the ordinary title owner still runs for a conversation this owner names
/// only implicitly.
class ScheduleConversationFactory {
  static final Logger _logger = Logger('ScheduleConversationFactory');

  /// Longest derived title taken from a task text, matching the session title
  /// snippet length the runtime already uses.
  static const int maxDerivedTitleLength = 60;

  final SessionManager _sessionManager;
  final SessionDB _db;
  final String Function()? _defaultModel;

  ScheduleConversationFactory({
    required SessionManager sessionManager,
    SessionDB? db,
    String Function()? defaultModel,
  }) : _sessionManager = sessionManager,
       _db = db ?? sessionManager.db,
       _defaultModel = defaultModel;

  /// Resolves the conversation a run must dispatch into, creating it when the
  /// row's mode requires one (S3, S4, D8, D10).
  ///
  /// - A model-owned row never creates a conversation: it runs in the
  ///   conversation that owns it, and an owner that no longer exists is a
  ///   caller error, not something to paper over here (D8, D10).
  /// - `continuous` reuses the stored `run_session_id` and creates exactly one
  ///   conversation when it is empty or gone (S3, S23).
  /// - `new_each_run` always creates a fresh conversation (S4).
  ///
  /// The returned identity is what the dispatch event addresses; the caller
  /// records it on the run row when the run's user message commits.
  String resolveDispatchSession(ScheduledTaskRecord record) {
    if (record.ownerKind == ScheduleOwnerKind.model) {
      return _modelOwnedSession(record);
    }
    if (record.conversationMode == ScheduleConversationMode.newEachRun) {
      return _createConversation(record);
    }
    final existing = record.runSessionId;
    if (existing != null && _sessionExists(existing)) return existing;
    final created = _createConversation(record);
    // Persist through the single edit path so a re-save by the scheduler can
    // never erase it (Task 139 write rules).
    _db.updateScheduleSettings(record.id, runSessionId: created);
    _logger.info(
      'Created conversation $created for continuous schedule ${record.id}',
    );
    return created;
  }

  String _modelOwnedSession(ScheduledTaskRecord record) {
    for (final candidate in [record.runSessionId, record.sessionId]) {
      if (candidate != null && candidate.trim().isNotEmpty) return candidate;
    }
    throw StateError(
      'Model-owned schedule ${record.id} has no owning conversation.',
    );
  }

  bool _sessionExists(String sessionId) =>
      _sessionManager.getSessionRecord(sessionId) != null;

  /// Creates one conversation with the schedule's stored workspace, provider,
  /// and model (S5).
  String _createConversation(ScheduledTaskRecord record) {
    final model = _resolveModel(record);
    final session = _sessionManager.createSession(
      model,
      providerId: record.providerInstanceId,
    );
    final derivedTitle = _derivedTitle(record);
    final namedTitle = record.name?.trim();
    if (namedTitle != null && namedTitle.isNotEmpty) {
      // A schedule name is the user's own words for this work, so it is a
      // final title and the intelligent title owner correctly stays idle.
      _saveWithWorkspace(
        session,
        workspaceId: record.workspaceId,
        title: namedTitle,
        titleStatus: SessionTitleStatus.finalized,
      );
    } else if (derivedTitle != null) {
      // No name: the derived label is the same placeholder the runtime would
      // derive from the message, and the ordinary title owner still replaces
      // it, so the generated title is never suppressed.
      _saveWithWorkspace(
        session,
        workspaceId: record.workspaceId,
        title: derivedTitle,
        titleStatus: SessionTitleStatus.pending,
      );
    } else {
      _saveWithWorkspace(session, workspaceId: record.workspaceId);
    }
    return session.sessionId;
  }

  void _saveWithWorkspace(
    SessionState session, {
    String? workspaceId,
    String? title,
    SessionTitleStatus? titleStatus,
  }) {
    final normalizedWorkspaceId = workspaceId?.trim();
    if ((normalizedWorkspaceId == null || normalizedWorkspaceId.isEmpty) &&
        title == null) {
      return;
    }
    _db.saveSession(
      SessionState(
        sessionId: session.sessionId,
        model: session.model,
        providerId: session.providerId,
        thinkingMode: session.thinkingMode,
        title: title ?? session.title,
        titleStatus: titleStatus ?? session.titleStatus,
        workspaceId: normalizedWorkspaceId == null ||
                normalizedWorkspaceId.isEmpty
            ? session.workspaceId
            : normalizedWorkspaceId,
        createdAt: session.createdAt,
        updatedAt: DateTime.now(),
        lastUserMessageAt: session.lastUserMessageAt,
        routeRevision: session.routeRevision,
        routeUpdatedAt: session.routeUpdatedAt,
        historyRevision: session.historyRevision,
      ),
    );
  }

  String _resolveModel(ScheduledTaskRecord record) {
    final stored = record.model?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final configured = _defaultModel?.call();
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim();
    }
    if (getIt.isRegistered<Config>()) return getIt<Config>().llmModel;
    return 'sanad-agent';
  }

  /// A label derived from the task text, or null when the text is empty.
  static String? _derivedTitle(ScheduledTaskRecord record) {
    final text = record.task.trim();
    if (text.isEmpty) return null;
    final snippet = text.split('\n').first.trim();
    if (snippet.isEmpty) return null;
    if (snippet.length <= maxDerivedTitleLength) return snippet;
    return '${snippet.substring(0, maxDerivedTitleLength - 3).trim()}...';
  }
}
