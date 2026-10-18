import 'dart:async';

enum ClientCliApprovalDecision {
  allowOnce,
  allowSession,
  deny,
}

class ClientCliApprovalRequest {
  final String id;
  final String deviceId;
  final String deviceName;
  final List<String> argv;
  final String? sessionId;
  final Completer<ClientCliApprovalDecision> completer;

  ClientCliApprovalRequest({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.argv,
    this.sessionId,
    required this.completer,
  });

  String get commandPreview => argv.join(' ');
}

class ClientCliApprovalCoordinator {
  final _requestController = StreamController<ClientCliApprovalRequest?>.broadcast();
  final Set<String> _approvedSessionIds = {};
  final List<ClientCliApprovalRequest> _queue = [];
  ClientCliApprovalRequest? _currentRequest;

  Stream<ClientCliApprovalRequest?> get requestStream => _requestController.stream;
  ClientCliApprovalRequest? get currentRequest => _currentRequest;
  int get queuedCount => _queue.length;

  bool isSessionApproved(String sessionId) =>
      _approvedSessionIds.contains(sessionId);

  Future<bool> requestApproval({
    required String id,
    required String deviceId,
    required String deviceName,
    required List<String> argv,
    String? sessionId,
  }) async {
    // If session is already approved, allow without prompt
    if (sessionId != null && _approvedSessionIds.contains(sessionId)) {
      return true;
    }

    final completer = Completer<ClientCliApprovalDecision>();
    final request = ClientCliApprovalRequest(
      id: id,
      deviceId: deviceId,
      deviceName: deviceName,
      argv: argv,
      sessionId: sessionId,
      completer: completer,
    );

    if (_currentRequest == null) {
      _currentRequest = request;
      _requestController.add(request);
    } else {
      _queue.add(request);
    }

    try {
      final decision = await completer.future;
      switch (decision) {
        case ClientCliApprovalDecision.allowOnce:
          return true;
        case ClientCliApprovalDecision.allowSession:
          if (sessionId != null && sessionId.isNotEmpty) {
            _approvedSessionIds.add(sessionId);
          }
          return true;
        case ClientCliApprovalDecision.deny:
          return false;
      }
    } finally {
      if (_currentRequest == request) {
        _advanceQueue();
      } else {
        _queue.remove(request);
      }
    }
  }

  void _advanceQueue() {
    while (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      if (next.sessionId != null && _approvedSessionIds.contains(next.sessionId)) {
        if (!next.completer.isCompleted) {
          next.completer.complete(ClientCliApprovalDecision.allowSession);
        }
        continue;
      }
      _currentRequest = next;
      _requestController.add(next);
      return;
    }

    _currentRequest = null;
    _requestController.add(null);
  }

  void resolveCurrent(ClientCliApprovalDecision decision) {
    final request = _currentRequest;
    if (request != null && !request.completer.isCompleted) {
      request.completer.complete(decision);
    }
  }

  void clearSessionApprovals() {
    _approvedSessionIds.clear();
  }

  void dispose() {
    resolveCurrent(ClientCliApprovalDecision.deny);
    for (final queued in _queue) {
      if (!queued.completer.isCompleted) {
        queued.completer.complete(ClientCliApprovalDecision.deny);
      }
    }
    _queue.clear();
    unawaited(_requestController.close());
    _approvedSessionIds.clear();
  }
}
