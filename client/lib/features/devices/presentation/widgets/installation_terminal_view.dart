import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';

class InstallationTerminalView extends StatefulWidget {
  final String versionTag;
  final VoidCallback onComplete;
  final void Function(String error) onFailure;

  const InstallationTerminalView({
    super.key,
    required this.versionTag,
    required this.onComplete,
    required this.onFailure,
  });

  @override
  State<InstallationTerminalView> createState() => _InstallationTerminalViewState();
}

class _InstallationTerminalViewState extends State<InstallationTerminalView> {
  late final LocalDaemonController _daemonController;
  late final DeviceConnectionCoordinator _connectionCoordinator;
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();

  double _downloadProgress = 0.0;
  String _currentStep =
      'idle'; // 'idle', 'directories', 'download', 'permissions', 'service', 'verify', 'success', 'failed'

  final List<Map<String, String>> _steps = [
    {'id': 'directories', 'title': 'Initialize setup and data directories'},
    {'id': 'download', 'title': 'Download precompiled agent binary'},
    {'id': 'permissions', 'title': 'Configure execution permissions'},
    {'id': 'service', 'title': 'Register system background service'},
    {'id': 'verify', 'title': 'Start service and verify connection'},
  ];

  @override
  void initState() {
    super.initState();
    _daemonController = GetIt.instance<LocalDaemonController>();
    _connectionCoordinator = GetIt.instance<DeviceConnectionCoordinator>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startInstallation());
    });
  }

  void _addLog(String message, {bool isError = false}) {
    setState(() {
      _logs.add('${isError ? "[ERROR]" : "[INFO]"} $message');
    });
    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        unawaited(
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  Future<void> _startInstallation() async {
    final targetVersion = widget.versionTag.startsWith('v') ? widget.versionTag.substring(1) : widget.versionTag;
    _addLog('Starting Sanad Agent lifecycle for $targetVersion...');

    setState(() => _currentStep = 'directories');
    _addLog('Preparing the owner-scoped Sanad Home...');

    setState(() => _currentStep = 'download');
    final result = await _daemonController.updateDaemon(
      targetVersion: targetVersion,
      onProgress: (progress) {
        if (mounted) setState(() => _downloadProgress = progress);
      },
    );
    if (!result.isSuccess) {
      _addLog(result.actionableMessage, isError: true);
      setState(() => _currentStep = 'failed');
      widget.onFailure(result.actionableMessage);
      return;
    }
    _addLog('The exact verified agent is installed.');

    setState(() => _currentStep = 'permissions');
    _addLog('Platform execution trust and permissions passed.');
    setState(() => _currentStep = 'service');
    _addLog('The background service is registered and started.');

    setState(() => _currentStep = 'verify');
    _addLog(
      'Health reports $targetVersion; authenticating the local socket...',
    );
    final socket = await _connectionCoordinator.ensureConnectedLocalRuntimeSocket();
    if (socket == null || !socket.isReady) {
      const message =
          'The agent is healthy, but the authenticated local connection could not be established. Try again.';
      _addLog(message, isError: true);
      setState(() => _currentStep = 'failed');
      widget.onFailure(message);
      return;
    }

    _addLog(
      'Verification successful. The agent version and authenticated connection are ready.',
    );
    setState(() => _currentStep = 'success');
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withValues(alpha: 0.1),
            blurRadius: 30,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Step status list
          ..._steps.map((step) {
            final stepId = step['id']!;
            final title = step['title']!;
            final isActive = _currentStep == stepId;
            final isDone = _isStepDone(stepId);

            Color iconColor = Colors.grey;
            IconData icon = Icons.circle_outlined;

            if (isActive) {
              iconColor = Colors.greenAccent;
              icon = Icons.sync;
            } else if (isDone) {
              iconColor = Colors.green;
              icon = Icons.check_circle;
            } else if (_currentStep == 'failed' && !_isStepDone(stepId)) {
              iconColor = Colors.redAccent;
              icon = Icons.cancel;
            }

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  isActive
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              iconColor,
                            ),
                          ),
                        )
                      : Icon(icon, color: iconColor, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: isActive
                            ? Colors.greenAccent
                            : isDone
                            ? Colors.white70
                            : Colors.grey,
                        fontSize: 14,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 16),
          if (_currentStep == 'download') ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _downloadProgress,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Colors.greenAccent,
                ),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Downloading: ${(_downloadProgress * 100).toStringAsFixed(1)}%',
              style: const TextStyle(
                color: Colors.greenAccent,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
              textAlign: TextAlign.left,
            ),
          ],
          const SizedBox(height: 16),
          // Terminal log box
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  final isError = log.startsWith('[ERROR]');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      log,
                      style: TextStyle(
                        color: isError ? Colors.redAccent : Colors.lightGreen,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      textDirection: TextDirection.ltr,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isStepDone(String stepId) {
    const stepOrder = [
      'directories',
      'download',
      'permissions',
      'service',
      'verify',
    ];
    final currentIndex = stepOrder.indexOf(_currentStep);
    if (currentIndex == -1) {
      if (_currentStep == 'success') return true;
      return false;
    }
    return stepOrder.indexOf(stepId) < currentIndex;
  }
}
