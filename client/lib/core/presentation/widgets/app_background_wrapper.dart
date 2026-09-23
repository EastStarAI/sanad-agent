import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';

class _AppBackgroundScope extends InheritedWidget {
  const _AppBackgroundScope({required super.child});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;
}

/// Wraps content with the selected appearance background, supporting
/// default theme background, solid accent colors, or nature wallpapers
/// with a theme-adaptive semi-transparent protective barrier (overlay scrim).
class AppBackgroundWrapper extends StatelessWidget {
  final Widget child;

  const AppBackgroundWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (context.dependOnInheritedWidgetOfExactType<_AppBackgroundScope>() != null) {
      return child;
    }

    return BlocBuilder<AppearanceCubit, AppearanceState>(
      builder: (context, appearance) {
        final option = appearance.backgroundOption;
        final theme = Theme.of(context);
        final isDark = appearance.themeStyle == AppThemeStyle.dark ||
            appearance.themeStyle == AppThemeStyle.midnight;

        Widget content;

        if (option == AppBackgroundOption.defaultTheme) {
          content = Material(
            color: theme.scaffoldBackgroundColor,
            child: child,
          );
        } else if (!option.isWallpaper) {
          final solidColor = switch (option) {
            AppBackgroundOption.solidSlate =>
              isDark ? const Color(0xFF20262E) : const Color(0xFFE5E9EE),
            AppBackgroundOption.solidNavy =>
              isDark ? const Color(0xFF0B132B) : const Color(0xFFE0E7F5),
            _ => theme.scaffoldBackgroundColor,
          };

          content = Material(
            color: solidColor,
            child: child,
          );
        } else {
          // Nature wallpaper with theme-adaptive semi-transparent protective barrier
          final scrimColor = switch (appearance.themeStyle) {
            AppThemeStyle.light => Colors.white.withValues(alpha: 0.75),
            AppThemeStyle.sepia => const Color(0xFFFBF0D9).withValues(alpha: 0.76),
            AppThemeStyle.dark => const Color(0xFF181818).withValues(alpha: 0.78),
            AppThemeStyle.midnight => const Color(0xFF000000).withValues(alpha: 0.82),
          };

          content = Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                option.assetPath!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                ),
              ),
              ColoredBox(
                color: scrimColor,
              ),
              Material(
                color: Colors.transparent,
                child: child,
              ),
            ],
          );
        }

        return _AppBackgroundScope(child: content);
      },
    );
  }
}
