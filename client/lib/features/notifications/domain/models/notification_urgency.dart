/// How loudly a notification should interrupt.
///
/// Urgency is an attribute of a kind, not a second taxonomy. The Agent decides
/// it per notification and every kind defaults to [high], which means banner
/// and sound; a user lowers an individual kind in Settings instead of the
/// product shipping a silent default.
enum NotificationUrgency {
  low('low'),
  normal('normal'),
  high('high'),
  critical('critical');

  const NotificationUrgency(this.wire);

  final String wire;

  /// The product default when the Agent sends no urgency it recognizes.
  static const NotificationUrgency defaultUrgency = NotificationUrgency.high;

  /// Resolves a wire token, falling back to [defaultUrgency].
  ///
  /// Unlike a kind, an unrecognized urgency is recoverable: the event still
  /// names a kind the user may have enabled, so it keeps the product default
  /// rather than dropping the notification entirely.
  static NotificationUrgency fromWire(Object? value) {
    if (value is! String) return defaultUrgency;
    final token = value.trim();
    for (final urgency in NotificationUrgency.values) {
      if (urgency.wire == token) return urgency;
    }
    return defaultUrgency;
  }

  /// True when the notification must be presented as an interruption rather
  /// than folded into a quiet summary.
  bool get isInterruptive =>
      this == NotificationUrgency.high || this == NotificationUrgency.critical;

  /// The quieter of two urgencies.
  ///
  /// The enum is declared from quietest to loudest, so the index is the rank.
  /// A preference can only ever lower a notification, which is why the display
  /// pipeline asks for the lower of the Agent's decision and the device's
  /// ceiling instead of letting either side win.
  static NotificationUrgency lowerOf(
    NotificationUrgency first,
    NotificationUrgency second,
  ) =>
      first.index <= second.index ? first : second;
}
