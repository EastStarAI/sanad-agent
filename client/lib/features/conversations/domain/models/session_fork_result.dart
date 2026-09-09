import 'session.dart';

class SessionForkResult {
  final String outcome;
  final Session? child;
  final bool navigationFailed;

  const SessionForkResult({
    required this.outcome,
    this.child,
    this.navigationFailed = false,
  });

  bool get isAccepted => outcome == 'accepted' || outcome == 'already_exists';

  factory SessionForkResult.fromJson(Map<String, dynamic> json) {
    final childRaw = json['child'];
    Session? child;
    if (childRaw is Map) {
      child = Session.fromJson(Map<String, dynamic>.from(childRaw));
    }
    return SessionForkResult(
      outcome: json['outcome']?.toString() ?? 'invalid_response',
      child: child,
      navigationFailed: json['navigation_failed'] == true,
    );
  }
}
