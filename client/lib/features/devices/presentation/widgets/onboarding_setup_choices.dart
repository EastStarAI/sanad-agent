import 'package:flutter/material.dart';

class OnboardingSetupChoices extends StatelessWidget {
  const OnboardingSetupChoices({
    required this.isDesktop,
    required this.isAuthenticated,
    required this.hasRegisteredDevices,
    required this.onRunLocally,
    required this.onRemoteAction,
    this.isLoadingDevices = false,
    this.onRetry,
    this.error,
    super.key,
  });

  final bool isDesktop;
  final bool isAuthenticated;
  final bool hasRegisteredDevices;
  final bool isLoadingDevices;
  final VoidCallback onRunLocally;
  final VoidCallback onRemoteAction;
  final VoidCallback? onRetry;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Phone layout has no local-install primary path, so a loading/error
    // inventory must be distinct from absence there. Desktop keeps local setup
    // primary and never flashes a false device absence for the remote path.
    final showDeviceInventoryState = !isDesktop && !hasRegisteredDevices;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BrandHeader(theme: theme),
        const SizedBox(height: 24),
        if (showDeviceInventoryState && isLoadingDevices)
          _InventoryLoadingState(theme: theme)
        else if (showDeviceInventoryState && error != null)
          _InventoryErrorState(
            theme: theme,
            message: error!,
            onRetry: onRetry,
            onRemoteAction: onRemoteAction,
          )
        else if (isDesktop)
          _DesktopChoices(
            theme: theme,
            isAuthenticated: isAuthenticated,
            hasRegisteredDevices: hasRegisteredDevices,
            onRunLocally: onRunLocally,
            onRemoteAction: onRemoteAction,
          )
        else
          _RemoteOnlyEmptyState(
            theme: theme,
            isAuthenticated: isAuthenticated,
            onRemoteAction: onRemoteAction,
          ),
        if (error != null && !showDeviceInventoryState) ...[
          const SizedBox(height: 24),
          Text(
            error!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

/// Distinct inventory-loading state shown while the backend fetch is in flight,
/// so the UI never flashes a false "No devices connected" (Plan 97g P09).
/// Uses a static green dot + English status only — no continuous-animation
/// indicator, consistent with the Windows static-activity policy (Plan 97 §3.4).
class _InventoryLoadingState extends StatelessWidget {
  const _InventoryLoadingState({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          key: const Key('inventory_loading_dot'),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.green,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Checking for your devices…',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Loading your connected Sanad Agents.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            height: 1.5,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

/// Distinct error state shown when the backend fetch fails, so the failure is
/// never presented as an authoritative empty device list.
class _InventoryErrorState extends StatelessWidget {
  const _InventoryErrorState({
    required this.theme,
    required this.message,
    required this.onRemoteAction,
    this.onRetry,
  });

  final ThemeData theme;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback onRemoteAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          Icons.cloud_off_outlined,
          size: 52,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 18),
        Text(
          'Couldn\u2019t load your devices',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            height: 1.5,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (onRetry != null) ...[
              OutlinedButton.icon(
                key: const Key('inventory_retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              const SizedBox(width: 12),
            ],
            FilledButton.icon(
              key: const Key('inventory_remote_action'),
              onPressed: onRemoteAction,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add a Remote Device'),
            ),
          ],
        ),
      ],
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.rocket_launch_outlined,
          size: 44,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 12),
        Text(
          'Sanad Agent',
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.bold,
            letterSpacing: -1,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _DesktopChoices extends StatelessWidget {
  const _DesktopChoices({
    required this.theme,
    required this.isAuthenticated,
    required this.hasRegisteredDevices,
    required this.onRunLocally,
    required this.onRemoteAction,
  });

  final ThemeData theme;
  final bool isAuthenticated;
  final bool hasRegisteredDevices;
  final VoidCallback onRunLocally;
  final VoidCallback onRemoteAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Set up Sanad Agent on this computer. No account is required.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            height: 1.5,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 24),
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('onboarding_run_locally'),
            onTap: onRunLocally,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.45),
                ),
                borderRadius: BorderRadius.circular(16),
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.computer_outlined,
                      color: theme.colorScheme.primary,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Run Sanad Locally',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Install Sanad Agent as a background service on this computer.',
                          style: TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'or',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.center,
          child: TextButton(
            key: const Key('onboarding_remote_action'),
            onPressed: onRemoteAction,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.72),
              textStyle: const TextStyle(
                fontSize: 14,
                decoration: TextDecoration.underline,
              ),
            ),
            child: Text(_remoteActionLabel()),
          ),
        ),
      ],
    );
  }

  String _remoteActionLabel() {
    if (!isAuthenticated) return 'Sign in to connect a remote device';
    if (hasRegisteredDevices) return 'Continue with connected devices';
    return 'Add a remote device';
  }
}

class _RemoteOnlyEmptyState extends StatelessWidget {
  const _RemoteOnlyEmptyState({
    required this.theme,
    required this.isAuthenticated,
    required this.onRemoteAction,
  });

  final ThemeData theme;
  final bool isAuthenticated;
  final VoidCallback onRemoteAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          Icons.devices_outlined,
          size: 52,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 18),
        Text(
          isAuthenticated ? 'No devices connected' : 'Connect to Sanad Agent',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          isAuthenticated
              ? 'Install Sanad Agent on a computer or server to access it from this device.'
              : 'Sign in to access Sanad Agent on your computers and servers.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            height: 1.5,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          key: const Key('onboarding_remote_action'),
          onPressed: onRemoteAction,
          icon: Icon(isAuthenticated ? Icons.add_rounded : Icons.login_rounded),
          label: Text(isAuthenticated ? 'Add a Remote Device' : 'Sign In'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
        ),
      ],
    );
  }
}
