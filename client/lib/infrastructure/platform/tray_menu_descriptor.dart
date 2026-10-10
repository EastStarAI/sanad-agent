import 'dart:async';

enum TrayMenuItemKind {
  action,
  info,
  separator,
}

class TrayMenuItemDescriptor {
  final String key;
  final String label;
  final TrayMenuItemKind kind;
  final bool isEnabled;
  final FutureOr<void> Function()? onSelected;

  const TrayMenuItemDescriptor({
    required this.key,
    required this.label,
    this.kind = TrayMenuItemKind.action,
    this.isEnabled = true,
    this.onSelected,
  });

  const TrayMenuItemDescriptor.separator({this.key = 'separator'})
      : label = '',
        kind = TrayMenuItemKind.separator,
        isEnabled = false,
        onSelected = null;

  const TrayMenuItemDescriptor.info({
    required this.key,
    required this.label,
  })  : kind = TrayMenuItemKind.info,
        isEnabled = false,
        onSelected = null;

  const TrayMenuItemDescriptor.action({
    required this.key,
    required this.label,
    this.isEnabled = true,
    required this.onSelected,
  }) : kind = TrayMenuItemKind.action;

  bool get isSeparator => kind == TrayMenuItemKind.separator;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TrayMenuItemDescriptor &&
        other.key == key &&
        other.label == label &&
        other.kind == kind &&
        other.isEnabled == isEnabled;
  }

  @override
  int get hashCode => Object.hash(key, label, kind, isEnabled);
}
