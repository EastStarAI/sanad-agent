/// Represents 2D screen coordinates and size of a rendered widget.
class UiBounds {
  final int x;
  final int y;
  final int width;
  final int height;

  const UiBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory UiBounds.fromJson(Map<String, dynamic> json) {
    return UiBounds(
      x: json['x'] as int? ?? 0,
      y: json['y'] as int? ?? 0,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  @override
  String toString() => '(${x}, ${y}) ${width}x${height}';
}

/// Represents an inspected widget in the Flutter UI element tree.
class UiElement {
  final String type;
  final String? key;
  final String? text;
  final String? hint;
  final String? tooltip;
  final String? semanticsLabel;
  final bool? selected;
  final bool button;

  /// Whether the control accepts input; null when the widget has no
  /// enabled state.
  final bool? enabled;
  final UiBounds? bounds;

  const UiElement({
    required this.type,
    this.key,
    this.text,
    this.hint,
    this.tooltip,
    this.semanticsLabel,
    this.selected,
    this.button = false,
    this.enabled,
    this.bounds,
  });

  factory UiElement.fromJson(Map<String, dynamic> json) {
    return UiElement(
      type: json['type'] as String? ?? 'Widget',
      key: json['key'] as String?,
      text: json['text'] as String?,
      hint: json['hint'] as String?,
      tooltip: json['tooltip'] as String?,
      semanticsLabel: json['semantics_label'] as String?,
      selected: json['selected'] as bool?,
      button: json['button'] as bool? ?? false,
      enabled: json['enabled'] as bool?,
      bounds: json['bounds'] != null
          ? UiBounds.fromJson(Map<String, dynamic>.from(json['bounds'] as Map))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (key != null) 'key': key,
    if (text != null) 'text': text,
    if (hint != null) 'hint': hint,
    if (tooltip != null) 'tooltip': tooltip,
    if (semanticsLabel != null) 'semantics_label': semanticsLabel,
    if (selected != null) 'selected': selected,
    if (button) 'button': true,
    if (enabled != null) 'enabled': enabled,
    if (bounds != null) 'bounds': bounds!.toJson(),
  };

  bool matches({
    String? keyFilter,
    String? textFilter,
    String? typeFilter,
    String? query,
  }) {
    if (keyFilter != null && key != keyFilter) return false;
    if (textFilter != null && text != textFilter) return false;
    if (typeFilter != null &&
        type.toLowerCase() != typeFilter.toLowerCase() &&
        !type.toLowerCase().endsWith(typeFilter.toLowerCase())) {
      return false;
    }
    if (query != null && query.isNotEmpty) {
      final q = query.toLowerCase();
      final inKey = key?.toLowerCase().contains(q) ?? false;
      final inText = text?.toLowerCase().contains(q) ?? false;
      final inHint = hint?.toLowerCase().contains(q) ?? false;
      final inTooltip = tooltip?.toLowerCase().contains(q) ?? false;
      final inSemantics = semanticsLabel?.toLowerCase().contains(q) ?? false;
      final inType = type.toLowerCase().contains(q);
      if (!inKey &&
          !inText &&
          !inHint &&
          !inTooltip &&
          !inSemantics &&
          !inType) {
        return false;
      }
    }
    return true;
  }
}

/// Evidence channel behind an action's post-condition verdict.
///
/// `verification` is always one of these wire values and `verified` is always
/// the matching boolean, so a strict consumer can type both fields. The channel
/// is a property of what was observed, not of what the caller asked for: the
/// same physical outcome reports the same value with or without `--verify`.
///
/// A channel that proves the post-condition (`key`, `present`, `absent`, `text`,
/// `tree`) reports `verified: true`. The remaining values describe why no
/// positive proof exists:
///
/// - `no_observable_change`: the action was dispatched and the bounded window
///   elapsed without an observable change.
/// - `none`: no evidence channel exists or produced a verdict at all — the
///   action failed before observation, verification was disabled, or the step
///   makes no post-condition claim.
/// - `type_census`: the rendered type census proved that the type is still
///   rendered, so the requested absence cannot be claimed.
enum UiVerification {
  key('key'),
  present('present'),
  absent('absent'),
  text('text'),
  tree('tree'),
  noObservableChange('no_observable_change'),
  none('none'),
  typeCensus('type_census');

  const UiVerification(this.wire);

  /// Stable JSON value of this channel; part of the public command contract.
  final String wire;

  /// Whether this channel proves the action's post-condition.
  bool get verified => _provingChannels.contains(this);

  /// Every wire value, in declaration order, for documentation and tests.
  static List<String> get wireValues =>
      UiVerification.values.map((channel) => channel.wire).toList();

  /// Parses a wire value back to its channel, or null when it is not part of
  /// the documented set.
  static UiVerification? fromWire(String value) {
    for (final channel in UiVerification.values) {
      if (channel.wire == value) return channel;
    }
    return null;
  }
}

const Set<UiVerification> _provingChannels = {
  UiVerification.key,
  UiVerification.present,
  UiVerification.absent,
  UiVerification.text,
  UiVerification.tree,
};

/// The result of an executed UI action.
class DriverActionResult {
  final bool success;
  final String action;
  final String message;
  final Map<String, dynamic>? data;
  final Duration duration;

  /// Exact widget key of the resolved target, when the action resolved one.
  final String? targetKey;

  /// Rendered target position in global coordinates, when the action reports
  /// one (tap).
  final int? x;
  final int? y;

  /// Snapshot generation observed after the action completed.
  final int? generation;

  /// Evidence channel behind this action's post-condition verdict. Always set,
  /// so `verification` is never absent from an action result.
  final UiVerification verification;

  /// Whether [verification] proves the post-condition. Always a boolean on the
  /// wire.
  bool get verified => verification.verified;

  const DriverActionResult({
    required this.success,
    required this.action,
    required this.message,
    this.data,
    required this.duration,
    this.targetKey,
    this.x,
    this.y,
    this.generation,
    required this.verification,
  });

  Map<String, dynamic> toJson() {
    final payload = <String, dynamic>{
      'success': success,
      'action': action,
      'message': message,
      'duration_ms': duration.inMilliseconds,
      if (data != null) 'data': data,
      if (targetKey != null) 'key': targetKey,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
    };
    if (generation != null) payload['generation'] = generation;
    payload['verified'] = verified;
    payload['verification'] = verification.wire;
    return payload;
  }

  @override
  String toString() =>
      '${success ? "✅" : "❌"} [$action] $message (${duration.inMilliseconds}ms)';
}

/// Represents a single step in a declarative batch test/interaction sequence.
class BatchStep {
  final String action; // tap, enter_text, scroll, wait_for, screenshot, sleep, snapshot, message_bodies
  final String? key;
  final String? text;
  final String? type;
  final String? within;
  final int? index;
  final double? x;
  final double? y;
  final double? dx;
  final double? dy;
  final String? to;
  final String? untilVisibleKey;
  final bool absent;
  final bool continueOnError;
  final String? out;
  final int? timeoutSeconds;
  final int? delayMs;
  final int? sleepMs;

  /// Post-condition keys for a `tap` step.
  final String? expect;
  final String? expectAbsent;

  /// Skips post-condition verification for a single step.
  final bool noVerify;

  /// Turns an unchanged tree from "reported" into a step failure.
  final bool strictVerify;

  /// Requests a quiesced re-capture for a `snapshot` step.
  final bool fresh;

  /// Judges the first probe of a `wait_for` step instead of waiting.
  final bool noWait;

  const BatchStep({
    required this.action,
    this.key,
    this.text,
    this.type,
    this.within,
    this.index,
    this.x,
    this.y,
    this.dx,
    this.dy,
    this.to,
    this.untilVisibleKey,
    this.absent = false,
    this.continueOnError = false,
    this.out,
    this.timeoutSeconds,
    this.delayMs,
    this.sleepMs,
    this.expect,
    this.expectAbsent,
    this.noVerify = false,
    this.strictVerify = false,
    this.fresh = false,
    this.noWait = false,
  });

  factory BatchStep.fromJson(Map<String, dynamic> json) {
    return BatchStep(
      action: json['action'] as String? ?? 'snapshot',
      key: json['key'] as String?,
      text: json['text'] as String?,
      type: json['type'] as String?,
      within: json['within'] as String?,
      index: (json['index'] as num?)?.toInt(),
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
      dx: (json['dx'] as num?)?.toDouble(),
      dy: (json['dy'] as num?)?.toDouble(),
      to: json['to'] as String?,
      untilVisibleKey:
          json['until_visible_key'] as String? ??
          json['until_visible'] as String?,
      absent: json['absent'] as bool? ?? false,
      continueOnError: json['continue_on_error'] as bool? ?? false,
      out: json['out'] as String? ?? json['output'] as String?,
      timeoutSeconds:
          json['timeout_seconds'] as int? ?? json['timeout'] as int?,
      delayMs: json['delay_ms'] as int? ?? json['delay'] as int?,
      sleepMs:
          json['sleep_ms'] as int? ??
          json['sleep'] as int? ??
          json['ms'] as int?,
      expect: json['expect'] as String?,
      expectAbsent:
          json['expect_absent'] as String? ?? json['expect_gone'] as String?,
      noVerify: json['no_verify'] as bool? ?? false,
      strictVerify: json['verify'] as bool? ?? false,
      fresh: json['fresh'] as bool? ?? false,
      noWait: json['no_wait'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'action': action,
    if (key != null) 'key': key,
    if (text != null) 'text': text,
    if (type != null) 'type': type,
    if (within != null) 'within': within,
    if (index != null) 'index': index,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (dx != null) 'dx': dx,
    if (dy != null) 'dy': dy,
    if (to != null) 'to': to,
    if (untilVisibleKey != null) 'until_visible_key': untilVisibleKey,
    if (absent) 'absent': absent,
    if (continueOnError) 'continue_on_error': continueOnError,
    if (out != null) 'out': out,
    if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
    if (delayMs != null) 'delay_ms': delayMs,
    if (sleepMs != null) 'sleep_ms': sleepMs,
    if (expect != null) 'expect': expect,
    if (expectAbsent != null) 'expect_absent': expectAbsent,
    if (noVerify) 'no_verify': noVerify,
    if (strictVerify) 'verify': strictVerify,
    if (fresh) 'fresh': fresh,
    if (noWait) 'no_wait': noWait,
  };
}
