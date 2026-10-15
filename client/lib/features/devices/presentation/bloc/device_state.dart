import 'package:equatable/equatable.dart';

import '../../domain/models/device_config.dart';

/// Typed device-inventory status for the "no active device" surface, so the UI
/// can clearly distinguish loading from an authoritative empty result and never
/// flashes a false "No devices" while a fetch is still in flight (Plan 97g P09).
///
/// In [DeviceNoActive]:
///  * [loading]   -> `isLoadingFromBackend == true` and no authoritative result yet.
///  * [readyEmpty]-> `isLoadingFromBackend == false`, `errorMessage == null`, list empty.
///  * [ready]     -> `isLoadingFromBackend == false`, `errorMessage == null`, and a cached
///                   list is retained with no active device selected (an active device is
///                   always represented by [DeviceActive], not by this phase).
///  * [stale]     -> `isLoadingFromBackend == true` while a previously cached list is retained.
///  * [error]     -> a fetch failed; `errorMessage != null` and any cached list is retained
///                   (cached data is never wiped and the user is never logged out).
///
/// A request timeout is a failure, never an authoritative empty: it resolves to
/// [error] (with retained [DeviceNoActive.agents]) instead of [readyEmpty].
enum DevicesPhase { loading, readyEmpty, ready, error, stale }

abstract class DeviceState extends Equatable {
  const DeviceState();

  @override
  List<Object?> get props => [];
}

class AgentInitial extends DeviceState {}

class DeviceLoading extends DeviceState {}

class DeviceActive extends DeviceState {
  final DeviceConfig activeAgent;
  final List<DeviceConfig> agents;

  const DeviceActive({required this.activeAgent, this.agents = const []});

  @override
  List<Object?> get props => [activeAgent, agents];

  DeviceActive copyWith({
    DeviceConfig? activeAgent,
    List<DeviceConfig>? agents,
  }) {
    return DeviceActive(
      activeAgent: activeAgent ?? this.activeAgent,
      agents: agents ?? this.agents,
    );
  }
}

class DeviceNoActive extends DeviceState {
  final List<DeviceConfig> agents;
  final bool isLoadingFromBackend;

  /// When set, the most recent inventory fetch failed (including timeout).
  /// Cached [agents] are retained (never wiped) and the auth session is left
  /// untouched, so a transient/remote failure does not cause a logout.
  final String? errorMessage;

  const DeviceNoActive({
    this.agents = const [],
    this.isLoadingFromBackend = false,
    this.errorMessage,
  });

  /// Typed status of the device inventory (Plan 97g).
  DevicesPhase get phase {
    if (errorMessage != null) return DevicesPhase.error;
    if (isLoadingFromBackend) {
      return agents.isEmpty ? DevicesPhase.loading : DevicesPhase.stale;
    }
    return agents.isEmpty ? DevicesPhase.readyEmpty : DevicesPhase.ready;
  }

  @override
  List<Object?> get props => [agents, isLoadingFromBackend, errorMessage];

  DeviceNoActive copyWith({
    List<DeviceConfig>? agents,
    bool? isLoadingFromBackend,
    String? errorMessage,
    bool clearError = false,
  }) {
    return DeviceNoActive(
      agents: agents ?? this.agents,
      isLoadingFromBackend: isLoadingFromBackend ?? this.isLoadingFromBackend,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class AgentError extends DeviceState {
  final String message;
  const AgentError(this.message);

  @override
  List<Object?> get props => [message];
}
