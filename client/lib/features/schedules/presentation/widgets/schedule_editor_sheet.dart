import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart' show Provider, ProviderNotFoundException;
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/cached_workspace_section.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_model_chip.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_workspace_chip.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_failure_text.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_format.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_recurrence_fields.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/workspace_picker_helper.dart';

/// The create and edit form for one schedule (Task 139 C2, S1, S6).
///
/// Field order follows the task: name, task (required, with the self-contained
/// hint), recurrence, advanced zone, workspace, provider and model, conversation
/// mode, live next-run preview, then Create or Save. Edit opens the same form
/// with the row as its initial value; the owning conversation is shown and is
/// not changeable.
///
/// Reuse (C3, S5): the workspace and model selectors are the shared composer
/// chips, and the model picker is the existing `ModelPickerDialog` opened by
/// that chip. No second picker lives under `features/schedules/`.
///
/// The preview is the Agent's answer (`schedule.preview`, D4): this form only
/// debounces the candidate and renders the returned instant in the selected
/// zone.
class ScheduleEditorSheet extends StatefulWidget {
  const ScheduleEditorSheet({
    super.key,
    required this.cubit,
    required this.device,
    this.schedule,
    this.cacheRepository,
    this.preferencesRepository,
  });

  final SchedulesCubit cubit;
  final DeviceConfig? device;

  /// `null` creates a new schedule; a row opens this form in edit mode.
  final Schedule? schedule;

  /// Workspace source and last-used route defaults; both are optional so the
  /// form still works where the conversation chrome is absent.
  final ConversationCacheRepository? cacheRepository;
  final IDevicePreferencesRepository? preferencesRepository;

  /// The debounce before a candidate definition is previewed.
  static const Duration previewDebounce = Duration(milliseconds: 350);

  /// Opens the form and reports whether the Agent accepted the mutation.
  static Future<bool?> show(
    BuildContext context, {
    required SchedulesCubit cubit,
    required DeviceConfig? device,
    Schedule? schedule,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => BlocProvider<SchedulesCubit>.value(
        value: cubit,
        child: ScheduleEditorSheet(
          cubit: cubit,
          device: device,
          schedule: schedule,
          cacheRepository: _maybeRead<ConversationCacheRepository>(context),
          preferencesRepository: _maybeRead<IDevicePreferencesRepository>(context),
        ),
      ),
    );
  }

  @override
  State<ScheduleEditorSheet> createState() => _ScheduleEditorSheetState();
}

/// A provider this surface can live without; a missing one is `null`, never an
/// exception, so the form does not depend on conversation-only registrations.
T? _maybeRead<T extends Object>(BuildContext context) {
  try {
    return Provider.of<T>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

class _ScheduleEditorSheetState extends State<ScheduleEditorSheet> {
  final _nameController = TextEditingController();
  final _taskController = TextEditingController();
  final _zoneController = TextEditingController();

  late ScheduleRecurrenceDraft _recurrence;
  late ScheduleConversationMode _mode;

  String? _workspaceId;
  String? _providerId;
  String? _modelId;

  String? _taskError;
  String? _timeError;
  String? _intervalError;
  String? _monthDayError;
  String? _weekdaysError;
  String? _onceError;
  String? _zoneError;
  String? _submitError;

  bool _submitting = false;
  String _timeText = '';
  Timer? _previewDebounce;

  List<DeviceWorkspace> _workspaces = const <DeviceWorkspace>[];
  bool _loadingWorkspaces = false;
  StreamSubscription<DeviceConversationCacheSnapshot>? _cacheSubscription;

  bool get _isEditing => widget.schedule != null;

  @override
  void initState() {
    super.initState();
    final schedule = widget.schedule;
    if (schedule == null) {
      _recurrence = const ScheduleRecurrenceDraft(
        atTime: TimeOfDay(hour: 9, minute: 0),
      );
      _mode = ScheduleConversationMode.continuous;
      _zoneController.text = 'local';
      final deviceId = widget.device?.id;
      if (deviceId != null) {
        _providerId = widget.preferencesRepository?.getLastProvider(deviceId);
        _modelId = widget.preferencesRepository?.getLastModel(deviceId);
      }
    } else {
      _nameController.text = schedule.name ?? '';
      _taskController.text = schedule.task;
      _zoneController.text = schedule.zone;
      _timeText = schedule.atTime ?? '';
      _recurrence = ScheduleRecurrenceDraft.fromSchedule(schedule);
      _mode = schedule.conversationMode == ScheduleConversationMode.unknown
          ? ScheduleConversationMode.continuous
          : schedule.conversationMode;
      _workspaceId = schedule.workspaceId;
      _providerId = schedule.providerInstanceId;
      _modelId = schedule.model;
    }
    _bindWorkspaces();
    // A stored definition is previewed as soon as the form opens; nothing is
    // requested from a build.
    if (_recurrence.isComplete) _schedulePreview();
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    unawaited(_cacheSubscription?.cancel());
    _nameController.dispose();
    _taskController.dispose();
    _zoneController.dispose();
    super.dispose();
  }

  void _bindWorkspaces() {
    final repository = widget.cacheRepository;
    final device = widget.device;
    if (repository == null || device == null) return;
    _readWorkspaces(repository, device.id, notify: false);
    _cacheSubscription = repository.snapshotStream.listen((_) {
      if (!mounted) return;
      _readWorkspaces(repository, device.id);
    });
    if (device.isOnline) {
      unawaited(repository.refreshWorkspaces(device));
    }
  }

  void _readWorkspaces(
    ConversationCacheRepository repository,
    String deviceId, {
    bool notify = true,
  }) {
    final CachedWorkspaceSection? section = repository.snapshot.contexts[deviceId]?.workspaces;
    final workspaces = section?.workspaces ?? const <DeviceWorkspace>[];
    final loading = section?.state == ConversationResourceState.loading;
    if (!notify) {
      _workspaces = workspaces;
      _loadingWorkspaces = loading;
      return;
    }
    setState(() {
      _workspaces = workspaces;
      _loadingWorkspaces = loading;
    });
  }

  DeviceWorkspace? get _selectedWorkspace {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return null;
    for (final workspace in _workspaces) {
      if (workspace.id == workspaceId) return workspace;
    }
    // A stored workspace the device no longer lists still renders by identity,
    // so an edit never silently drops the route it was given.
    return DeviceWorkspace(id: workspaceId, name: workspaceId, path: '');
  }

  Future<void> _createWorkspace() async {
    final repository = widget.cacheRepository;
    final device = widget.device;
    if (repository == null || device == null) return;
    final selected = await WorkspacePickerHelper.promptCreateWorkspace(
      context: context,
      device: device,
      remoteBrowser: WorkspaceBrowserCallbacks.forDevice(repository, device),
    );
    if (selected == null || !mounted) return;
    final workspace = await repository.createWorkspace(
      device,
      path: selected.path,
      name: selected.name,
      description: selected.description,
    );
    if (workspace == null || !mounted) return;
    setState(() => _workspaceId = workspace.id);
  }

  void _onRecurrenceChanged(ScheduleRecurrenceDraft next) {
    setState(() {
      _recurrence = next;
      _timeError = null;
      _intervalError = null;
      _monthDayError = null;
      _weekdaysError = null;
      _onceError = null;
      _submitError = null;
    });
    _schedulePreview();
  }

  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(ScheduleEditorSheet.previewDebounce, _requestPreview);
  }

  void _requestPreview() {
    if (!mounted) return;
    if (!_recurrence.isComplete) {
      widget.cubit.clearPreview();
      return;
    }
    unawaited(widget.cubit.preview(_recurrence.toDefinition(zone: _zoneValue)));
  }

  /// The zone token to send: omitted for an empty field, so the Agent keeps its
  /// own default instead of the Client inventing one.
  String? get _zoneValue {
    final token = _zoneController.text.trim();
    return token.isEmpty ? null : token;
  }

  bool get _zoneIsValid {
    final token = _zoneValue;
    if (token == null) return true;
    if (token.toLowerCase() == 'local') return true;
    return parseScheduleZoneOffset(token) != null;
  }

  Future<void> _pickOnceInstant() async {
    final now = DateTime.now();
    final initial = _recurrence.at?.toLocal() ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted) return;
    final chosenTime = time ?? TimeOfDay.fromDateTime(initial);
    final instant = DateTime(
      date.year,
      date.month,
      date.day,
      chosenTime.hour,
      chosenTime.minute,
    ).toUtc();
    setState(() {
      _recurrence = _recurrence.copyWith(at: instant);
      _onceError = null;
    });
    _schedulePreview();
  }

  bool _validate(AppLocalizations l10n) {
    final taskText = _taskController.text.trim();
    final timeUsable = !_recurrence.usesClockTime || _recurrence.atTime != null;
    setState(() {
      _taskError = taskText.isEmpty ? l10n.scheduleTaskRequired : null;
      _zoneError = _zoneIsValid ? null : l10n.scheduleInvalidZone;
      _timeError = !_recurrence.usesClockTime
          ? null
          : _recurrence.atTime != null
          ? null
          : _timeText.trim().isEmpty
          ? l10n.scheduleTimeRequired
          : l10n.scheduleInvalidTime;
      _intervalError = _recurrence.kind == ScheduleKind.interval && _recurrence.intervalMinutes <= 0
          ? l10n.scheduleIntervalRequired
          : null;
      _weekdaysError = _recurrence.kind == ScheduleKind.weekly && _recurrence.weekdays.isEmpty
          ? l10n.scheduleWeekdaysRequired
          : null;
      _monthDayError =
          _recurrence.kind == ScheduleKind.monthly &&
              ((_recurrence.monthDay ?? 0) < 1 || (_recurrence.monthDay ?? 0) > 31)
          ? l10n.scheduleDayOfMonthRequired
          : null;
      _onceError = _recurrence.kind == ScheduleKind.once ? _recurrence.validationError(l10n) : null;
      _submitError = null;
    });
    return _taskError == null &&
        _zoneError == null &&
        timeUsable &&
        _timeError == null &&
        _intervalError == null &&
        _weekdaysError == null &&
        _monthDayError == null &&
        _onceError == null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final l10n = AppLocalizations.of(context)!;
    if (!_validate(l10n)) return;
    setState(() => _submitting = true);

    final taskText = _taskController.text.trim();
    final name = _nameController.text.trim();
    final definition = _recurrence.toDefinition(zone: _zoneValue);
    final schedule = widget.schedule;
    final outcome = schedule == null
        ? await widget.cubit.create(
            ScheduleDraft(
              task: taskText,
              name: name.isEmpty ? null : name,
              definition: definition,
              conversationMode: _mode,
              workspaceId: _workspaceId,
              providerInstanceId: _providerId,
              model: _modelId,
            ),
          )
        : await widget.cubit.update(
            ScheduleUpdate(
              id: schedule.id,
              task: taskText,
              name: ScheduleSetting.set(name.isEmpty ? null : name),
              conversationMode: _mode,
              workspaceId: ScheduleSetting.set(_workspaceId),
              providerInstanceId: ScheduleSetting.set(_providerId),
              model: ScheduleSetting.set(_modelId),
              definition: definition,
            ),
          );
    if (!mounted) return;
    if (outcome == ScheduleActionOutcome.success) {
      Navigator.of(context).pop(true);
      return;
    }
    final failure = widget.cubit.state.failure;
    setState(() {
      _submitting = false;
      _submitError = failure == null
          ? l10n.scheduleSaveFailed
          : scheduleFailureText(l10n, failure.code) ?? l10n.scheduleSaveFailed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final online = widget.device?.isOnline ?? false;

    return Padding(
      key: const Key('schedule_editor_sheet'),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The title and the primary action stay outside the scrolling
                // body so the action is always reachable in a long form.
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text(
                    _isEditing ? l10n.scheduleEditTitle : l10n.scheduleNewTitle,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (_isEditing)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: _OwnerLine(schedule: widget.schedule!),
                  ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          key: const Key('schedule_editor_name_field'),
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: l10n.scheduleName,
                            helperText: l10n.scheduleNameOptional,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('schedule_editor_task_field'),
                          controller: _taskController,
                          minLines: 2,
                          maxLines: 5,
                          decoration: InputDecoration(
                            labelText: l10n.scheduleTask,
                            helperText: l10n.scheduleTaskHint,
                            helperMaxLines: 3,
                            errorText: _taskError,
                            errorMaxLines: 3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ScheduleRecurrenceFields(
                          draft: _recurrence,
                          onChanged: _onRecurrenceChanged,
                          onPickOnceInstant: () => unawaited(_pickOnceInstant()),
                          onTimeInput: (value) => _timeText = value,
                          timeError: _timeError,
                          intervalError: _intervalError,
                          monthDayError: _monthDayError,
                          weekdaysError: _weekdaysError,
                          onceError: _onceError,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('schedule_editor_zone_field'),
                          controller: _zoneController,
                          decoration: InputDecoration(
                            labelText: l10n.scheduleZone,
                            helperText: l10n.scheduleZoneHint,
                            errorText: _zoneError,
                          ),
                          onChanged: (_) {
                            if (_zoneError != null) setState(() => _zoneError = null);
                            _schedulePreview();
                          },
                        ),
                        const SizedBox(height: 16),
                        _SectionLabel(label: l10n.scheduleWorkspace),
                        const SizedBox(height: 6),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: ComposerWorkspaceChip(
                            key: const Key('schedule_editor_workspace_chip'),
                            availableWorkspaces: _workspaces,
                            selectedWorkspace: _selectedWorkspace,
                            isLoadingWorkspaces: _loadingWorkspaces,
                            requiresWorkspace: false,
                            hasActiveAgent: online,
                            isLocked: false,
                            chipBgColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                            borderColor: colorScheme.outline.withValues(alpha: 0.3),
                            dimTextColor: colorScheme.onSurfaceVariant,
                            onRefreshWorkspaces: () {
                              final repository = widget.cacheRepository;
                              final device = widget.device;
                              if (repository != null && device != null) {
                                unawaited(repository.refreshWorkspaces(device));
                              }
                            },
                            onWorkspaceSelected: (workspace) => setState(() => _workspaceId = workspace.id),
                            onWorkspaceCleared: () => setState(() => _workspaceId = null),
                            onAddNewWorkspace: () => unawaited(_createWorkspace()),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _SectionLabel(label: l10n.scheduleModel),
                        const SizedBox(height: 6),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: ComposerModelChip(
                            key: const Key('schedule_editor_model_chip'),
                            activeAgent: widget.device,
                            providerId: _providerId,
                            modelId: _modelId,
                            contextUsage: null,
                            session: null,
                            dimTextColor: colorScheme.onSurfaceVariant,
                            chipBgColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                            borderColor: colorScheme.outline.withValues(alpha: 0.3),
                            onModelSelected: (providerId, modelId) => setState(() {
                              _providerId = providerId;
                              _modelId = modelId;
                            }),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SwitchListTile.adaptive(
                          key: const Key('schedule_editor_mode_switch'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.scheduleConversationMode),
                          subtitle: Text(
                            _mode == ScheduleConversationMode.newEachRun
                                ? l10n.scheduleModeNewEachRunHint
                                : l10n.scheduleModeContinuousHint,
                            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                          ),
                          value: _mode == ScheduleConversationMode.newEachRun,
                          onChanged: (newEachRun) => setState(() {
                            _mode = newEachRun
                                ? ScheduleConversationMode.newEachRun
                                : ScheduleConversationMode.continuous;
                          }),
                        ),
                        const SizedBox(height: 12),
                        _SchedulePreviewView(zone: _zoneValue),
                        if (_submitError != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _submitError!,
                            key: const Key('schedule_editor_error'),
                            style: TextStyle(color: colorScheme.error, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const Key('schedule_editor_cancel_btn'),
                        onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('schedule_editor_submit_btn'),
                        onPressed: !online || _submitting ? null : () => unawaited(_submit()),
                        child: Text(_isEditing ? l10n.scheduleSave : l10n.scheduleCreate),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The owning conversation, when there is one: shown, never editable (S6).
class _OwnerLine extends StatelessWidget {
  const _OwnerLine({required this.schedule});

  final Schedule schedule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final ownerSessionId = schedule.ownerSessionId;
    return Row(
      key: const Key('schedule_editor_owner_readonly'),
      children: [
        Icon(Icons.forum_outlined, size: 16, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ownerSessionId == null
                ? l10n.scheduleOwnedByDevice
                : l10n.scheduleOwnedByConversation(
                    schedule.ownerSessionTitle?.trim().isNotEmpty == true
                        ? schedule.ownerSessionTitle!.trim()
                        : ownerSessionId,
                  ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        Icon(Icons.lock_outline, size: 14, color: colorScheme.onSurfaceVariant),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
    );
  }
}

/// The live next-run preview (D4): the Agent's answer, debounced and rendered in
/// the selected zone, with the invalid state spelled out.
class _SchedulePreviewView extends StatelessWidget {
  const _SchedulePreviewView({required this.zone});

  final String? zone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return BlocBuilder<SchedulesCubit, SchedulesState>(
      buildWhen: (previous, current) =>
          previous.preview != current.preview ||
          previous.previewInFlight != current.previewInFlight ||
          previous.previewFailure != current.previewFailure,
      builder: (context, state) {
        final preview = state.preview;
        final failure = state.previewFailure;
        String? detail;
        String value;
        if (state.previewInFlight) {
          value = '…';
        } else if (failure != null) {
          value = l10n.schedulePreviewInvalid;
          detail = scheduleFailureText(l10n, failure.code);
        } else if (preview == null) {
          return const SizedBox.shrink();
        } else if (!preview.valid) {
          value = l10n.schedulePreviewInvalid;
          final code = preview.errorCode;
          detail = code == null ? null : scheduleFailureText(l10n, code);
        } else {
          final nextRunAt = preview.nextRunAt;
          value = nextRunAt == null
              ? l10n.scheduleNextRunUnknown
              : formatScheduleInstant(context, nextRunAt, zone: preview.zone ?? zone);
        }
        return Row(
          key: const Key('schedule_editor_preview'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              preview?.valid == true && failure == null ? Icons.event_available_outlined : Icons.info_outline,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${l10n.scheduleNextRunPreview}: $value',
                    style: TextStyle(color: colorScheme.onSurface, fontSize: 12),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: TextStyle(color: colorScheme.error, fontSize: 11),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
