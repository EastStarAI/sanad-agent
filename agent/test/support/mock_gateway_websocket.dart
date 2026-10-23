import 'dart:async';
import 'dart:io';

/// In-memory [WebSocket] that lets a test script the gateway side.
///
/// Test-only double for `LocalGatewayCliClient`: it records every frame the
/// client sends ([sentMessages]) and injects gateway frames with
/// [emitFromServer], so a test can drive the real event-classification path
/// without a listening daemon.
class MockGatewayWebSocket implements WebSocket {
  final _incomingController = StreamController<dynamic>();
  final List<String> sentMessages = [];
  bool _closed = false;
  final Completer<void> _doneCompleter = Completer<void>();

  void emitFromServer(dynamic data) {
    if (!_closed) {
      _incomingController.add(data);
    }
  }

  void simulateClose([int? closeCode, String? closeReason]) {
    if (!_closed) {
      _closed = true;
      _incomingController.close();
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  void simulateError(Object error) {
    if (!_closed) {
      _incomingController.addError(error);
    }
  }

  @override
  void add(dynamic data) {
    if (_closed) throw const SocketException('Socket closed');
    sentMessages.add(data.toString());
  }

  @override
  Future close([int? code, String? reason]) async {
    simulateClose(code, reason);
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _incomingController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future get done => _doneCompleter.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
