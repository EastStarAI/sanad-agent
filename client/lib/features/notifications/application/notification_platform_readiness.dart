import 'dart:async';

/// The one signal that the platform objects a permission read depends on exist.
///
/// A platform builds the channel or D-Bus objects it answers with inside
/// `initialize`: the Linux adapter talks to a remote object that does not exist
/// before that call returns, and reading the capability first throws instead of
/// reporting the truth. A read that arrives first therefore waits here rather
/// than reporting the platform as unavailable, which would otherwise become a
/// display-policy refusal for every Agent-raised notification until something
/// else refreshed the permission.
///
/// Two facts make this a single owner rather than a rule inside the cubit:
///
/// - The pipeline is the only writer: [NotificationService.start] is the one
///   caller of `initialize`, so the bridge that starts it releases the read once
///   initialization has returned.
/// - The reader is every surface that reports or applies the permission, so the
///   gate belongs to the composition that owns both, not to the Settings page.
///
/// An absent instance means "no gate": a cubit built without one (a widget test,
/// a surface with no pipeline) reads immediately, which is the behavior every
/// existing caller already had.
class NotificationPlatformReadiness {
  final Completer<void> _ready = Completer<void>();

  /// Completes when the platform can answer a permission read.
  ///
  /// It never completes with an error: a failed initialization is still an
  /// answer, and reporting it as such is the permission read's job.
  Future<void> get ready => _ready.future;

  /// Whether the platform has already been released for reads.
  bool get isReady => _ready.isCompleted;

  /// Releases the permission read. Idempotent, so a second bridge in the same
  /// process (a restart of the mounted tree) cannot throw.
  void complete() {
    if (_ready.isCompleted) return;
    _ready.complete();
  }
}
