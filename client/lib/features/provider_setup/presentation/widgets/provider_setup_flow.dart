import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/api_key_provider_form.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/custom_endpoint_form.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/device_code_auth_view.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/loopback_auth_view.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/model_selection_view.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_picker_view.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_instances_list_view.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_instance_form_view.dart';

/// Self-contained, reusable provider setup surface.
///
/// Embeds the full catalog → authenticate → model selection flow and emits
/// [onReady] once the agent reports `provider.runtime_check` ready. Designed
/// for reuse from both onboarding and future settings without rewriting the
/// controller/state layer.
///
/// Pass [device] to target a specific remote device (Sanad Gateway); leave null
/// for the local daemon.
class ProviderSetupFlow extends StatefulWidget {
  final DeviceConfig? device;
  final ValueChanged<ProviderReadinessDto>? onReady;
  final bool showReadyState;
  final bool autoLoad;
  final ProviderSetupClient? client;
  final bool globalAutoFailoverEnabled;
  final VerificationPageLauncher? verificationLauncher;

  const ProviderSetupFlow({
    super.key,
    this.device,
    this.onReady,
    this.showReadyState = true,
    this.autoLoad = true,
    this.client,
    this.globalAutoFailoverEnabled = true,
    this.verificationLauncher,
  });

  @override
  State<ProviderSetupFlow> createState() => _ProviderSetupFlowState();
}

class _ProviderSetupFlowState extends State<ProviderSetupFlow> {
  late ProviderSetupCubit _cubit;
  late ProviderUsageCubit _usageCubit;
  late bool _ownsUsageCubit;
  StreamSubscription? _instanceIdsSub;

  ProviderSetupClient get _client => widget.client ?? getIt<ProviderSetupClient>();

  @override
  void initState() {
    super.initState();
    _initializeControllers();
  }

  void _initializeControllers() {
    _cubit = ProviderSetupCubit(
      client: _client,
      agent: widget.device,
      showReadyState: widget.showReadyState,
    );
    _ownsUsageCubit = widget.client != null;
    _usageCubit = _ownsUsageCubit
        ? ProviderUsageCubit(
            client: _client,
            localDeviceId: widget.device?.id ?? getIt<String>(instanceName: 'hardwareId'),
          )
        : getIt<ProviderUsageCubit>();

    // Whenever the configured instances change, refresh the daemon's usage
    // support map and fetch usage in parallel for supported instances. This is
    // non-blocking: the instances list renders first and usage fills in
    // afterwards (Task 55 §3.5).
    _instanceIdsSub = _cubit.stream
        .map((s) => s.instances.map((i) => i.id).toList())
        .distinct((a, b) => _listEquals(a, b))
        .skip(1)
        .listen((ids) {
          unawaited(
            _usageCubit.onInstancesLoaded(
              agent: widget.device,
              instanceIds: ids,
            ),
          );
        });

    if (widget.autoLoad) {
      unawaited(_cubit.load());
    }
  }

  @override
  void didUpdateWidget(covariant ProviderSetupFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final deviceChanged = oldWidget.device?.id != widget.device?.id;
    final clientChanged = !identical(oldWidget.client, widget.client);
    if (!deviceChanged && !clientChanged) return;

    _disposeControllers();
    _initializeControllers();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _disposeControllers() {
    unawaited(_instanceIdsSub?.cancel());
    _instanceIdsSub = null;
    unawaited(_cubit.close());
    if (_ownsUsageCubit) {
      unawaited(_usageCubit.close());
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    final asET = a.join('|');
    final bsET = b.join('|');
    return asET == bsET;
  }

  void _notifyReady(ProviderSetupState state) {
    final readiness = state.readiness;
    if (readiness != null) {
      widget.onReady?.call(readiness);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: _cubit),
        BlocProvider.value(value: _usageCubit),
      ],
      child: BlocListener<ProviderSetupCubit, ProviderSetupState>(
        listenWhen: (prev, next) => prev.readiness?.runtimeReady != true && next.readiness?.runtimeReady == true,
        listener: (context, state) {
          _notifyReady(state);
        },
        child: BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
          builder: (context, state) {
            final body = AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _buildBody(context, state),
            );
            return LayoutBuilder(
              builder: (context, constraints) {
                if (!constraints.hasBoundedHeight) return body;
                final ownsStepScroll = switch (state.status) {
                  ProviderSetupStatus.instanceForm ||
                  ProviderSetupStatus.modelSelection ||
                  ProviderSetupStatus.deviceCode ||
                  ProviderSetupStatus.loopback => true,
                  _ => false,
                };
                if (ownsStepScroll) {
                  return SizedBox(height: constraints.maxHeight, child: body);
                }
                return SingleChildScrollView(
                  key: ValueKey('provider_setup_scroll_${state.status.name}'),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: body,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ProviderSetupState state) {
    switch (state.status) {
      case ProviderSetupStatus.initial:
      case ProviderSetupStatus.loading:
        return _LoadingView(message: state.loadingMessage ?? 'Loading...');
      case ProviderSetupStatus.picker:
        return const ProviderPickerView();
      case ProviderSetupStatus.apiKey:
        return const ApiKeyProviderForm();
      case ProviderSetupStatus.customEndpoint:
        return const CustomEndpointForm();
      case ProviderSetupStatus.deviceCode:
        return DeviceCodeAuthView(
          verificationLauncher: widget.verificationLauncher,
        );
      case ProviderSetupStatus.loopback:
        return const LoopbackAuthView();
      case ProviderSetupStatus.modelSelection:
        return const ModelSelectionView();
      case ProviderSetupStatus.instancesList:
        return const ProviderInstancesListView();
      case ProviderSetupStatus.instanceForm:
        return ProviderInstanceFormView(
          globalAutoFailoverEnabled: widget.globalAutoFailoverEnabled,
        );
      case ProviderSetupStatus.saving:
        return _LoadingView(message: state.loadingMessage ?? 'Saving...');
      case ProviderSetupStatus.ready:
        return _ReadyView(onContinue: () => _notifyReady(state));
      case ProviderSetupStatus.error:
        return _ErrorView(
          message: state.error ?? 'Something went wrong.',
          onRetry: () => unawaited(_cubit.load()),
        );
    }
  }
}

class _LoadingView extends StatelessWidget {
  final String message;
  const _LoadingView({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadyView extends StatelessWidget {
  final VoidCallback onContinue;
  const _ReadyView({required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Provider is ready',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continue'),
            onPressed: onContinue,
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Colors.redAccent.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
