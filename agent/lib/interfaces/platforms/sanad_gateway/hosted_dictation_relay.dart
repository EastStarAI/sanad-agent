/// Hosted dictation relay: the daemon end of the authenticated cloud channel.
///
/// One instance per gateway platform owns at most one hosted dictation session
/// and one bounded control operation. It never creates a conversation session,
/// session identity, or client tag, and it never touches the shared socket's
/// listeners: the platform registers the three relay events once and forwards
/// them here, and this owner simply stops accepting them when nothing is live.
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../../infrastructure/stt/dictation_service.dart';
import '../../../infrastructure/stt/dictation_session.dart';
import '../../../infrastructure/stt/hosted_dictation_channel.dart';

/// One bounded catalog/control operation over the hosted control path.
///
/// It holds no map entry per `dictation_id`: a new command replaces the single
/// current operation, and the operation retires itself (or is retired by an
/// abort or a disconnect) so no producer outlives its origin claim.
class _HostedControlOperation {
  _HostedControlOperation({
    required this.dictationId,
    required this.requestId,
    required this.deadline,
    required this.clock,
    required this.clientTag,
  });

  final String dictationId;
  final String requestId;
  final DateTime deadline;
  final DateTime Function() clock;
  final String? clientTag;

  bool retired = false;

  bool get expired => retired || clock().isAfter(deadline);

  void retire() => retired = true;
}

class HostedDictationRelay {
  HostedDictationRelay({
    required DictationService service,
    required String Function() registeredDeviceId,
    required void Function(Map<String, dynamic> envelope, {String? clientTag})
    emitDeviceEvent,
    this.limits = const DictationRelayLimits(),
    DateTime Function()? clock,
    Uuid uuid = const Uuid(),
  }) : _service = service,
       _registeredDeviceId = registeredDeviceId,
       _emitDeviceEvent = emitDeviceEvent,
       _clock = clock ?? DateTime.now,
       _uuid = uuid;

  /// The command family this relay answers on the existing command path.
  static const String commandName = 'dictation';

  /// The single relayed daemon-event name; the canonical event name rides in
  /// `payload.type`, so the vocabulary is unchanged and the channel stays
  /// addressable.
  static const String eventName = 'dictation_event';

  static const Set<String> _controlOps = {
    'status',
    'install',
    'cancelInstall',
    'select',
    'prepareRuntime',
  };

  final DictationService _service;
  final String Function() _registeredDeviceId;
  final void Function(Map<String, dynamic> envelope, {String? clientTag})
  _emitDeviceEvent;
  final DictationRelayLimits limits;
  final DateTime Function() _clock;
  final Uuid _uuid;

  final Logger _logger = Logger('HostedDictationRelay');

  HostedDictationChannel? _session;
  _HostedControlOperation? _control;

  bool get hasSession => _session != null;
  bool get hasControlOperation => _control != null;

  /// Handles one `command == "dictation"` envelope from the gateway.
  ///
  /// The caller dispatches this before the conversation-session fall-through, so
  /// no session channel, session identity, or client tag is created here.
  Future<void> handleCommand(
    Map<String, dynamic> envelope, {
    String? clientTag,
  }) async {
    final payload = _asMap(envelope['payload']);
    final op = payload['op'];
    final dictationId = payload['dictation_id'];
    final requestId = envelope['request_id']?.toString() ??
        payload['request_id']?.toString();
    final envelopeDevice =
        envelope['device_id']?.toString() ?? payload['device_id']?.toString();

    // The device boundary is checked before anything is emitted: a command that
    // names another device is never forwarded and never answered.
    final registered = _registeredDeviceId();
    if (envelopeDevice != null &&
        envelopeDevice.isNotEmpty &&
        registered.isNotEmpty &&
        envelopeDevice != registered) {
      _logger.warning('hosted dictation dropped: wrong device');
      return;
    }
    if (requestId == null || requestId.isEmpty) {
      _logger.warning('hosted dictation dropped: missing request identity');
      return;
    }
    if (dictationId is! String || !_isValidIdentity(dictationId)) {
      _emitEvent(
        requestId: requestId,
        dictationId: dictationId is String ? dictationId : '',
        event: 'dictation_error',
        payload: {
          'code': 'invalid_request',
          'message': 'dictation_id is missing or malformed',
        },
        clientTag: clientTag,
      );
      return;
    }
    if (requestId != dictationId) {
      _emitEvent(
        requestId: requestId,
        dictationId: dictationId,
        event: 'dictation_error',
        payload: {
          'code': 'invalid_request',
          'message': 'request_id must equal dictation_id',
        },
        clientTag: clientTag,
      );
      return;
    }
    final version = payload['version'];
    if (version != null && version != 'v1' && version != 1) {
      _emitEvent(
        requestId: requestId,
        dictationId: dictationId,
        event: 'dictation_error',
        payload: {
          'code': 'incompatible',
          'message': 'unsupported dictation command version',
        },
        clientTag: clientTag,
      );
      return;
    }
    if (op is! String || op.isEmpty) {
      _emitError(
        requestId: requestId,
        dictationId: dictationId,
        code: 'invalid_request',
        message: 'op is required',
        clientTag: clientTag,
      );
      return;
    }

    if (op == 'start') {
      await _start(dictationId, requestId, clientTag);
      return;
    }
    if (op == 'stop' || op == 'cancel') {
      _emitError(
        requestId: requestId,
        dictationId: dictationId,
        code: 'invalid_request',
        message: 'stop and cancel travel on the ordered dictation_end control',
        clientTag: clientTag,
      );
      return;
    }
    if (!_controlOps.contains(op)) {
      _emitError(
        requestId: requestId,
        dictationId: dictationId,
        code: 'invalid_request',
        message: 'unknown dictation op',
        clientTag: clientTag,
      );
      return;
    }

    final operation = _HostedControlOperation(
      dictationId: dictationId,
      requestId: requestId,
      deadline: _clock().add(limits.producerDeadline),
      clock: _clock,
      clientTag: clientTag,
    );
    _control = operation;
    final modelId = payload['model_id'] as String?;
    final command = switch (op) {
      'status' => DictationCommand.status,
      'install' => DictationCommand.install,
      'cancelInstall' => DictationCommand.cancelInstall,
      'select' => DictationCommand.select,
      _ => DictationCommand.prepareRuntime,
    };
    final message = DictationMessage(command, {
      'model_id': ?modelId,
    });
    void emit(String event, Map<String, dynamic> fields) {
      // A retired claim or an expired producer deadline drops the event: the
      // Gateway rejects it anyway, and the daemon must not keep producing.
      if (operation.expired) return;
      _emitEvent(
        requestId: operation.requestId,
        dictationId: operation.dictationId,
        event: event,
        payload: fields,
        clientTag: operation.clientTag,
      );
    }

    if (command == DictationCommand.install) {
      // A download outlives this dispatch and this operation: it is
      // daemon-scoped, and only an explicit `cancelInstall` stops it. Progress
      // is addressed to the relay (the channel), so a later command from the
      // same device keeps receiving it; the operation's own expiry still drops
      // events that can no longer be delivered.
      unawaited(
        _service.control.handle(
          message,
          owner: operation,
          emit: emit,
          installChannel: this,
        ),
      );
      return;
    }
    await _service.control.handle(
      message,
      owner: operation,
      emit: emit,
      installChannel: this,
    );
  }

  Future<void> _start(
    String dictationId,
    String requestId,
    String? clientTag,
  ) async {
    final existing = _session;
    if (existing != null && !existing.isClosed) {
      if (existing.dictationId == dictationId) {
        // A repeated `start` for the same session is a reconnect or a double
        // press, not a second session.
        existing.send('stt_status', _service.statusPayload());
        return;
      }
      _emitError(
        requestId: requestId,
        dictationId: dictationId,
        code: 'dictation_busy',
        message: 'another hosted dictation session is running',
        clientTag: clientTag,
      );
      return;
    }
    late final HostedDictationChannel channel;
    channel = HostedDictationChannel(
      dictationId: dictationId,
      requestId: requestId,
      deviceId: _registeredDeviceId(),
      limits: limits,
      clock: _clock,
      emit: (event, payload) => _emitEvent(
        requestId: requestId,
        dictationId: dictationId,
        event: event,
        payload: payload,
        clientTag: clientTag,
      ),
      onClosed: () {
        if (identical(_session, channel)) _session = null;
      },
    );
    _session = channel;
    _logger.info('hosted dictation session accepted');
    unawaited(
      _service.handleChannel(channel).whenComplete(() {
        if (identical(_session, channel)) _session = null;
      }),
    );
    // The channel buffers the start until the service subscribes, so the one
    // session path begins here without a second engine or session owner.
    channel.beginSession();
  }

  /// `dictation_audio` frame forwarded by the gateway.
  ///
  /// Frames for any other session are dropped: one daemon serving two sessions
  /// can never cross-wire audio.
  void onAudioFrame(Map<String, dynamic> frame) {
    final session = _session;
    if (session == null) return;
    session.onAudioFrame(frame);
  }

  /// Ordered `dictation_end` control (`stopped` / `cancelled`).
  void onOrderedControl(Map<String, dynamic> control) {
    final dictationId = control['dictation_id'];
    if (dictationId is! String || dictationId.isEmpty) return;
    final requestId = control['request_id']?.toString();
    final session = _session;
    if (session != null &&
        session.dictationId == dictationId &&
        (requestId == null || requestId.isEmpty || requestId == session.requestId)) {
      session.onOrderedControl(control);
      return;
    }
    // No route was ever opened, or the session is already gone: the claim owner
    // still gets a typed answer, and nothing else happens.
    if (requestId == null || requestId.isEmpty) return;
    _emitError(
      requestId: requestId,
      dictationId: dictationId,
      code: 'unavailable',
      message: 'no hosted dictation session for this id',
    );
  }

  /// `dictation_abort`: advisory-but-authoritative cancellation **of a session**.
  ///
  /// A model install is not a session and is daemon-scoped: an abort, a client
  /// disconnect, or a lost claim only retires this relay's delivery operation, so
  /// the download keeps running and the next `status` from any client reports
  /// it. Only the explicit `cancelInstall` command stops an install.
  void onAbort(Map<String, dynamic> data) {
    final dictationId = data['dictation_id'];
    if (dictationId is! String || dictationId.isEmpty) return;
    final requestId = data['request_id']?.toString();
    final reason = data['reason']?.toString() ?? 'aborted';
    final session = _session;
    if (session != null &&
        session.dictationId == dictationId &&
        (requestId == null || requestId.isEmpty || requestId == session.requestId)) {
      session.onAbort(reason);
    }
    final control = _control;
    if (control != null && control.dictationId == dictationId) {
      control.retire();
    }
  }

  /// The shared cloud socket is gone: close this relay's own live objects.
  ///
  /// The install deliberately outlives it — it belongs to the daemon, and the
  /// local channel (or a reconnected relay) keeps receiving its truth.
  Future<void> closeAll() async {
    final session = _session;
    _session = null;
    if (session != null) await session.close();
    final control = _control;
    control?.retire();
    _control = null;
    _service.control.detachInstallChannel(this);
  }

  void _emitError({
    required String requestId,
    required String dictationId,
    required String code,
    required String message,
    String? clientTag,
  }) {
    _emitEvent(
      requestId: requestId,
      dictationId: dictationId,
      event: 'dictation_error',
      payload: {'code': code, 'message': message},
      clientTag: clientTag,
    );
  }

  /// Composes the origin-scoped relay envelope.
  ///
  /// `delivery.scope` is always `origin`, the request id is client-supplied and
  /// equal to the session identity, and the envelope deliberately carries no
  /// conversation `session_id`.
  void _emitEvent({
    required String requestId,
    required String dictationId,
    required String event,
    required Map<String, dynamic> payload,
    String? clientTag,
  }) {
    _emitDeviceEvent({
      'type': 'device_event',
      'event': eventName,
      'event_id': _uuid.v4(),
      'request_id': requestId,
      'delivery': {'scope': 'origin', 'request_id': requestId},
      'payload': {
        'version': 'v1',
        'dictation_id': dictationId,
        'type': event,
        ...payload,
      },
    }, clientTag: clientTag);
  }

  static bool _isValidIdentity(String value) {
    if (value.isEmpty || value.length > 128) return false;
    return RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }
}
