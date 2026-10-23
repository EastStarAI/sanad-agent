import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

class BackgroundSelectionGrid extends StatelessWidget {
  final AppBackgroundOption selected;
  final AppThemeStyle themeStyle;
  final ValueChanged<AppBackgroundOption> onSelected;

  const BackgroundSelectionGrid({
    required this.selected,
    required this.themeStyle,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = AppBackgroundOption.values;

    return LayoutBuilder(
      builder: (context, constraints) {
        const crossAxisCount = 3;
        const spacing = 12.0;
        final totalSpacing = spacing * (crossAxisCount - 1);
        final itemWidth = ((constraints.maxWidth - totalSpacing) / crossAxisCount).floorToDouble();

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: options.map((option) {
            final isSelected = option == selected;
            final label = switch (option) {
              AppBackgroundOption.defaultTheme => l10n.backgroundDefault,
              AppBackgroundOption.solidSlate => l10n.backgroundSlate,
              AppBackgroundOption.solidNavy => l10n.backgroundNavy,
              AppBackgroundOption.natureForest => l10n.backgroundForest,
              AppBackgroundOption.natureMountain => l10n.backgroundMountain,
              AppBackgroundOption.natureLake => l10n.backgroundLake,
            };

            return InkWell(
              key: Key('background_option_${option.name}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelected(option),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: itemWidth,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
                    width: isSelected ? 2 : 1,
                  ),
                  color: isSelected
                      ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15)
                      : Colors.transparent,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 70,
                        width: double.infinity,
                        child: _buildThumbnail(context, option),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isSelected) ...[
                          Icon(
                            Icons.check_circle,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildThumbnail(BuildContext context, AppBackgroundOption option) {
    final theme = Theme.of(context);
    final isDark = themeStyle == AppThemeStyle.dark || themeStyle == AppThemeStyle.midnight;

    if (option == AppBackgroundOption.defaultTheme) {
      return Container(
        color: theme.scaffoldBackgroundColor,
        child: Center(
          child: Icon(
            Icons.format_paint_outlined,
            color: theme.colorScheme.onSurfaceVariant,
            size: 24,
          ),
        ),
      );
    }

    if (!option.isWallpaper) {
      final solidColor = switch (option) {
        AppBackgroundOption.solidSlate =>
          isDark ? const Color(0xFF20262E) : const Color(0xFFE5E9EE),
        AppBackgroundOption.solidNavy =>
          isDark ? const Color(0xFF0B132B) : const Color(0xFFE0E7F5),
        _ => theme.scaffoldBackgroundColor,
      };
      return Container(color: solidColor);
    }

    // Wallpaper thumbnail with theme-adaptive barrier representation
    final scrimColor = switch (themeStyle) {
      AppThemeStyle.light => Colors.white.withValues(alpha: 0.70),
      AppThemeStyle.sepia => const Color(0xFFFBF0D9).withValues(alpha: 0.72),
      AppThemeStyle.dark => const Color(0xFF181818).withValues(alpha: 0.72),
      AppThemeStyle.midnight => const Color(0xFF000000).withValues(alpha: 0.78),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          option.assetPath!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(color: theme.scaffoldBackgroundColor),
        ),
        ColoredBox(color: scrimColor),
      ],
    );
  }
}
