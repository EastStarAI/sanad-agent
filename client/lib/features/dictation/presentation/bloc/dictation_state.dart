import 'package:equatable/equatable.dart';

/// How live transcript text is surfaced in the composer.
enum DictationPreviewPolicy { live, onStop }

/// Session lifecycle of one dictation run.
enum DictationStatus { idle, preparing, listening, finalizing }

/// One catalog entry as reported by the daemon.
class DictationModelOption extends Equatable {
  const DictationModelOption({
    required this.id,
    required this.label,
    this.note,
    this.totalBytes,
    this.hosted = false,
    this.installed = false,
  });

  final String id;
  final String label;
  final String? note;
  final int? totalBytes;
  final bool hosted;
  final bool installed;

  @override
  List<Object?> get props => [id, label, note, totalBytes, hosted, installed];
}

/// Daemon-reported speech model state (`stt_status` + `stt_download_progress`).
class DictationModelStatus extends Equatable {
  const DictationModelStatus({
    this.selectedModelId,
    this.isReady = false,
    this.downloadProgress,
    this.installedBytes,
    this.unavailableReason,
    this.models = const [],
  });

  final String? selectedModelId;
  final bool isReady;

  /// 0..1 while a download is in flight, null otherwise.
  final double? downloadProgress;
  final int? installedBytes;

  /// Daemon-side reason the engine cannot run (platform, native library, ...).
  final String? unavailableReason;

  /// Full catalog as reported by the daemon (for the model sheet).
  final List<DictationModelOption> models;

  bool get isDownloading => downloadProgress != null;

  DictationModelStatus copyWith({
    String? selectedModelId,
    bool? isReady,
    double? downloadProgress,
    bool clearDownloadProgress = false,
    int? installedBytes,
    String? unavailableReason,
    List<DictationModelOption>? models,
  }) {
    return DictationModelStatus(
      selectedModelId: selectedModelId ?? this.selectedModelId,
      isReady: isReady ?? this.isReady,
      downloadProgress:
          clearDownloadProgress ? null : (downloadProgress ?? this.downloadProgress),
      installedBytes: installedBytes ?? this.installedBytes,
      unavailableReason: unavailableReason ?? this.unavailableReason,
      models: models ?? this.models,
    );
  }

  @override
  List<Object?> get props => [
        selectedModelId,
        isReady,
        downloadProgress,
        installedBytes,
        unavailableReason,
        models,
      ];
}

class DictationState extends Equatable {
  const DictationState({
    this.status = DictationStatus.idle,
    this.model = const DictationModelStatus(),
    this.previewPolicy = DictationPreviewPolicy.live,
    this.committedText = '',
    this.partialText = '',
    this.errorCode,
    this.sessionNeedsFirstUseSheet = false,
  });

  final DictationStatus status;
  final DictationModelStatus model;
  final DictationPreviewPolicy previewPolicy;

  /// Text the daemon finalized in this session (never mutated afterwards).
  final String committedText;

  /// Unstable tail of the current segment; empty under [onStop].
  final String partialText;

  final String? errorCode;

  /// True when the session stopped because no model is installed yet.
  final bool sessionNeedsFirstUseSheet;

  bool get isActive =>
      status == DictationStatus.preparing ||
      status == DictationStatus.listening ||
      status == DictationStatus.finalizing;

  bool get isRecording => status == DictationStatus.listening;

  /// What the composer should show for this session right now.
  String get visibleText => '$committedText$partialText';

  DictationState copyWith({
    DictationStatus? status,
    DictationModelStatus? model,
    DictationPreviewPolicy? previewPolicy,
    String? committedText,
    String? partialText,
    String? errorCode,
    bool clearError = false,
    bool? sessionNeedsFirstUseSheet,
  }) {
    return DictationState(
      status: status ?? this.status,
      model: model ?? this.model,
      previewPolicy: previewPolicy ?? this.previewPolicy,
      committedText: committedText ?? this.committedText,
      partialText: partialText ?? this.partialText,
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
      sessionNeedsFirstUseSheet:
          sessionNeedsFirstUseSheet ?? this.sessionNeedsFirstUseSheet,
    );
  }

  @override
  List<Object?> get props => [
        status,
        model,
        previewPolicy,
        committedText,
        partialText,
        errorCode,
        sessionNeedsFirstUseSheet,
      ];
}
