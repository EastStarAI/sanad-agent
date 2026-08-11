import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/features/devices/presentation/widgets/device_install_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  String? _generatedToken;
  String? _createdDeviceId;
  String? _createdDeviceName;
  bool _isCreating = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _createDevice(GatewayConnectionStatus gatewayStatus) {
    if (!_formKey.currentState!.validate()) return;
    if (!gatewayStatus.isCloudReady) {
      setState(() {
        _error = 'Connect to SanadGateway before creating a remote device.';
      });
      return;
    }

    final deviceCubit = context.read<DeviceCubit>();
    final deviceName = _nameController.text.trim();

    setState(() {
      _isCreating = true;
      _error = null;
      _generatedToken = null;
      _createdDeviceId = null;
      _createdDeviceName = deviceName;
    });

    deviceCubit.createAgent(deviceName, type: 'computer');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocListener<DeviceCubit, DeviceState>(
      listener: _handleDeviceStateChange,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: AppPlatform.isMacOS ? 44 : 8,
                  bottom: 8,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'Back',
                      onPressed: () {
                        if (context.canPop()) {
                          context.pop();
                        } else {
                          context.go(AppRoutes.home);
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Add Host Device',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.outline.withValues(alpha: 0.12),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: theme.colorScheme.outline.withValues(alpha: 0.18),
                          ),
                        ),
                        color: theme.colorScheme.surface,
                        child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.smart_toy_outlined,
                              size: 48,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _generatedToken == null ? 'Create a remote host device' : 'Install and connect your device',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _generatedToken == null
                              ? 'Create a device record, then run the generated install command on your computer or server.'
                              : 'Run one of these commands on the target machine. Sanad will continue automatically when it connects.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                        ),
                        const SizedBox(height: 28),
                        if (_generatedToken == null) ...[
                          TextFormField(
                            controller: _nameController,
                            style: TextStyle(color: theme.colorScheme.onSurface),
                            decoration: InputDecoration(
                              labelText: 'Device Name',
                              labelStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                              border: const OutlineInputBorder(),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.24)),
                              ),
                              prefixIcon: Icon(Icons.label_outline, color: theme.colorScheme.onSurfaceVariant),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Please enter a name';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          if (_error != null) _ErrorMessage(message: _error!),
                          BlocBuilder<GatewayConnectionCubit, GatewayConnectionStatus>(
                            builder: (context, gatewayStatus) {
                              return ElevatedButton(
                                onPressed: _isCreating ? null : () => _createDevice(gatewayStatus),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: theme.colorScheme.primary,
                                  foregroundColor: theme.colorScheme.onPrimary,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: _isCreating
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      )
                                    : Text(
                                        'Create Host Device',
                                        style: TextStyle(
                                          color: theme.colorScheme.onPrimary,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                              );
                            },
                          ),
                        ] else ...[
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.check_circle_outline, color: theme.colorScheme.primary, size: 24),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Device Created Successfully',
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                DeviceInstallGuide(token: _generatedToken!),
                                const SizedBox(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Waiting for the device to come online...',
                                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: () => context.go(AppRoutes.home),
                                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                                  label: const Text('Continue to Home'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  ),
),
),
);
}

  void _handleDeviceStateChange(BuildContext context, DeviceState state) {
    final devices = state is DeviceActive ? state.agents : (state is DeviceNoActive ? state.agents : const []);
    final createdName = _createdDeviceName;

    if (_isCreating && createdName != null && devices.isNotEmpty) {
      final matches = devices.where((device) => device.name == createdName && device.token != null);
      if (matches.isNotEmpty) {
        final device = matches.last;
        setState(() {
          _isCreating = false;
          _generatedToken = device.token;
          _createdDeviceId = device.id;
        });
      }
    }

    final createdDeviceId = _createdDeviceId;
    if (createdDeviceId != null) {
      final createdMatches = devices.where((device) => device.id == createdDeviceId && device.isOnline);
      if (createdMatches.isNotEmpty) {
        unawaited(HapticFeedback.lightImpact());
        ToastUtils.showSuccess(context, '${createdMatches.first.name} is connected');
        context.go(AppRoutes.home);
      }
    }
  }
}

class _ErrorMessage extends StatelessWidget {
  final String message;

  const _ErrorMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
