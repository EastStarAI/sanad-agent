import 'package:equatable/equatable.dart';

enum VoiceSessionStatus {
  inactive,
  connecting,
  listening,
  speaking,
  error,

  /// The relay refused this session because one side is outdated or sent no
  /// identity. The UI presents an update-required state; there is no degraded
  /// fallback, because the only alternative is the broadcast the identity
  /// contract removed.
  updateRequired,
}

class VoiceStreamState extends Equatable {
  final bool isSessionActive;
  final VoiceSessionStatus status;
  final String? errorMessage;
  final String? activeAgentId;
  final String? activeSessionId;

  /// Account-scoped device identity this session claims with. The Gateway
  /// authenticates this id, not the local device row id.
  final String? activeAccountDeviceId;
  final bool isMuted;

  const VoiceStreamState({
    this.isSessionActive = false,
    this.status = VoiceSessionStatus.inactive,
    this.errorMessage,
    this.activeAgentId,
    this.activeSessionId,
    this.activeAccountDeviceId,
    this.isMuted = false,
  });

  VoiceStreamState copyWith({
    bool? isSessionActive,
    VoiceSessionStatus? status,
    String? errorMessage,
    String? activeAgentId,
    String? activeSessionId,
    String? activeAccountDeviceId,
    bool? isMuted,
    bool clearError = false,
  }) {
    return VoiceStreamState(
      isSessionActive: isSessionActive ?? this.isSessionActive,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      activeAgentId: activeAgentId ?? this.activeAgentId,
      activeSessionId: activeSessionId ?? this.activeSessionId,
      activeAccountDeviceId: activeAccountDeviceId ?? this.activeAccountDeviceId,
      isMuted: isMuted ?? this.isMuted,
    );
  }

  @override
  List<Object?> get props => [
    isSessionActive,
    status,
    errorMessage,
    activeAgentId,
    activeSessionId,
    activeAccountDeviceId,
    isMuted,
  ];
}
