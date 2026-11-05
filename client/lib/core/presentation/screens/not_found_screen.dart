import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/core/theme/app_typography.dart';

class NotFoundScreen extends StatelessWidget {
  final String? errorMessage;

  const NotFoundScreen({Key? key, this.errorMessage}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Page Not Found'),
        centerTitle: true,
      ),
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 80,
                color: colorScheme.error.withValues(alpha: 0.8),
              ),
              const SizedBox(height: 24),
              Text(
                '404',
                style: theme.textTheme.displayLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Oops! The page you are looking for doesn\'t exist.',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (errorMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colorScheme.error.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    errorMessage!,
                    style: AppTypography.mono(
                      textStyle: theme.textTheme.bodySmall,
                      color: colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () {
                  context.go(AppRoutes.home);
                },
                icon: const Icon(Icons.home_rounded),
                label: const Text('Return to Home'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
