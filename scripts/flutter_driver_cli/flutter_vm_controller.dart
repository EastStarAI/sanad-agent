import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:flutter_driver/flutter_driver.dart';

import 'models.dart';
import 'tree_state.dart';

class _DriverException implements Exception {
  const _DriverException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _conciseError(Object error) => error.toString().split('\n').first.trim();

String _rpcErrorMessage(Object? error) {
  if (error is Map) {
    final data = error['data'];
    if (data is Map) {
      final details = data['details'];
      if (details is String) {
        try {
          final decoded = json.decode(details);
          if (decoded is Map && decoded['error'] != null) {
            return decoded['error'].toString();
          }
        } on FormatException {
          // Fall through to the VM service message.
        }
      }
    }
    if (error['message'] != null) return error['message'].toString();
  }
  return error?.toString() ?? 'Unknown VM service error';
}

/// One inspected widget tree plus its change-detection signature.
class UiTreeCapture {
  const UiTreeCapture(this.elements, this.signature, {this.settled = true});

  final List<UiElement> elements;
  final String signature;

  /// False when a settle wait expired before two consecutive captures agreed.
  final bool settled;
}

/// Bounded census of the runtime widget types that are actually rendered.
///
/// The inspected tree intentionally emits only keyed, textual, tooltip-bearing,
/// or interactive widgets, so an uninspected type is indistinguishable from an
/// absent one. The census answers "is this type rendered at all", which is what
/// an absence claim requires.
class UiTypeCensus {
  const UiTypeCensus(
    this.types, {
    required this.truncated,
    this.visitedElements = 0,
  });

  final Set<String> types;

  /// True when the client stopped enumerating; absence is then unprovable.
  final bool truncated;

  /// Rendered elements the Client walked before it stopped.
  ///
  /// Zero when the Client does not report a walk count, which keeps the
  /// truncation diagnostic accurate against an older driver entry point.
  final int visitedElements;

  bool contains(String typeFilter) {
    final needle = typeFilter.toLowerCase();
    return types.any((type) {
      final candidate = type.toLowerCase();
      return candidate == needle || candidate.endsWith(needle);
    });
  }
}

/// Guidance returned when a scrolled-for target cannot be reached.
const String offstageTargetGuidance =
    'target offstage/not found; navigate first';

/// Default window used to observe an action's post-condition.
const Duration defaultVerifyTimeout = Duration(milliseconds: 2000);

/// Appended to a tap result when the Client does not register
/// `ext.sanad_client.reveal`.
///
/// An unrevealed baseline may predate an auto-scroll, so an observed tree
/// change is weaker evidence than a revealed one: it may be the scroll rather
/// than the action. The note is reported on success as well as on failure,
/// because a verified tap on an unrevealed baseline carries the same caveat.
const String revealUnavailableNote =
    ' Reveal was unavailable on this Client, so verification may be affected '
    'by auto-scroll.';

/// Resolves the deadline a single batch step runs under.
///
/// A step may declare its own `timeout_seconds`; otherwise it inherits the
/// batch `--timeout` that the launcher budgets the whole recipe with. Sharing
/// that one value keeps the wall clock and the enforced deadline from drifting
/// apart, which is what a hidden per-step default would do.
Duration batchStepTimeout(BatchStep step, Duration? defaultStepTimeout) =>
    step.timeoutSeconds != null
    ? Duration(seconds: step.timeoutSeconds!)
    : defaultStepTimeout ?? const Duration(seconds: 30);

/// Longest deadline any step in [steps] can run under.
///
/// The VM Service transport timeout must never be shorter than a step's own
/// deadline, or a deliberately slow step dies as a transport error before its
/// budget is spent.
Duration batchRpcTimeout(List<BatchStep> steps, Duration defaultStepTimeout) {
  var longest = defaultStepTimeout;
  for (final step in steps) {
    final stepTimeout = batchStepTimeout(step, defaultStepTimeout);
    if (stepTimeout > longest) longest = stepTimeout;
  }
  return longest;
}

/// Controller that coordinates Sanad VM service extensions and optional
/// Flutter Driver screenshot capture.
///
/// Every action is bounded: the RPC transport ([rpcTimeout]), the action
/// itself, and any post-condition verification window all terminate on a
/// deadline so a hung Client can never block a caller indefinitely.
class FlutterVmController {
  final String serviceUrl;
  final String wsUrl;
  FlutterDriver? _driver;
  WebSocket? _socket;
  StreamSubscription? _socketSub;
  final Map<int, Completer<dynamic>> _pendingRpc = {};
  final Map<String, String> _isolateByExtension = {};
  int _requestId = 100;

  /// Hard deadline for one VM Service RPC.
  Duration rpcTimeout = const Duration(seconds: 30);

  /// Snapshot counter used to stamp action results; unset means no stamping.
  UiTreeGenerationStore? generationStore;

  FlutterVmController._({required this.serviceUrl, required this.wsUrl});

  /// Factory to initialize and connect to the running Flutter instance.
  static Future<FlutterVmController> connect({
    String? explicitUrl,
    bool connectDriver = true,
  }) async {
    final url = await resolveVmServiceUrl(explicitUrl: explicitUrl);
    if (url == null) {
      throw StateError(
        'Could not discover active Dart VM Service URL.\n'
        'Ensure the Flutter application is running with VM Service enabled\n'
        'or provide --vm-url / set VM_SERVICE_URL environment variable.',
      );
    }

    var wsBase = url
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');
    while (wsBase.endsWith('/')) {
      wsBase = wsBase.substring(0, wsBase.length - 1);
    }
    final wsUrl = wsBase.endsWith('/ws') ? wsBase : '$wsBase/ws';

    final controller = FlutterVmController._(serviceUrl: url, wsUrl: wsUrl);

    if (connectDriver) {
      await controller._ensureDriverConnected();
    }

    return controller;
  }

  /// Automatically resolves the VM Service URL from explicit argument, env, or process scan.
  static Future<String?> resolveVmServiceUrl({String? explicitUrl}) async {
    if (explicitUrl != null && explicitUrl.trim().isNotEmpty) {
      return explicitUrl.trim();
    }

    final envUrl = Platform.environment['VM_SERVICE_URL'];
    if (envUrl != null && envUrl.trim().isNotEmpty) {
      return envUrl.trim();
    }

    return null;
  }

  Future<void> _ensureDriverConnected() async {
    if (_driver != null) return;
    try {
      _driver = await FlutterDriver.connect(dartVmServiceUrl: wsUrl);
    } catch (e) {
      throw _DriverException(
        'Failed to connect FlutterDriver to $wsUrl: ${_conciseError(e)}',
      );
    }
  }

  Future<WebSocket> _ensureSocket() async {
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      return _socket!;
    }
    _socket = await WebSocket.connect(wsUrl);
    _socketSub = _socket!.listen(
      (message) {
        try {
          final response = json.decode(message as String);
          final id = response['id'];
          if (id != null && _pendingRpc.containsKey(id)) {
            final completer = _pendingRpc.remove(id)!;
            if (response['error'] != null) {
              completer.completeError(
                _DriverException(_rpcErrorMessage(response['error'])),
              );
            } else {
              completer.complete(response['result']);
            }
          }
        } catch (_) {}
      },
      onError: (err) {
        for (final c in _pendingRpc.values) {
          if (!c.isCompleted) c.completeError(err);
        }
        _pendingRpc.clear();
      },
      onDone: () {
        for (final c in _pendingRpc.values) {
          if (!c.isCompleted) c.completeError('Socket closed');
        }
        _pendingRpc.clear();
      },
    );
    return _socket!;
  }

  Future<dynamic> _callRpc(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final socket = await _ensureSocket();
    final reqId = ++_requestId;
    final completer = Completer<dynamic>();
    _pendingRpc[reqId] = completer;

    socket.add(
      json.encode({
        'jsonrpc': '2.0',
        'method': method,
        'params': params ?? {},
        'id': reqId,
      }),
    );

    try {
      return await completer.future.timeout(rpcTimeout);
    } catch (error) {
      // A Client hot restart replaces its isolates; drop the cached selection so
      // the next probe rediscovers instead of failing forever.
      if (_conciseError(error).toLowerCase().contains('isolate')) {
        _isolateByExtension.clear();
      }
      rethrow;
    } finally {
      _pendingRpc.remove(reqId);
    }
  }

  /// Snapshot the complete UI hierarchy using `ext.sanad_client.inspect_ui`.
  Future<List<UiElement>> snapshot({
    String? filter,
    String? within,
    bool includeBounds = true,
    bool onlyWithKeys = false,
    bool interactiveOnly = false,
  }) async {
    final isolateId = await _discoverIsolateId('ext.sanad_client.inspect_ui');

    try {
      final result =
          await _callRpc('ext.sanad_client.inspect_ui', {
            'isolateId': isolateId,
            'includeBounds': includeBounds.toString(),
            'onlyWithKeys': onlyWithKeys.toString(),
            'interactiveOnly': interactiveOnly.toString(),
            if (within != null) 'within': within,
            if (filter != null) 'filter': filter,
          }) as Map<String, dynamic>? ??
          {};

      final elementsJson = result['elements'] as List? ?? [];
      return elementsJson
          .map((e) => UiElement.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      throw _DriverException('Snapshot failed: ${_conciseError(e)}');
    }
  }

  /// Captures the tree together with its change-detection signature.
  Future<UiTreeCapture> captureTree({
    String? filter,
    String? within,
    bool includeBounds = true,
    bool onlyWithKeys = false,
    bool interactiveOnly = false,
  }) async {
    final elements = await snapshot(
      filter: filter,
      within: within,
      includeBounds: includeBounds,
      onlyWithKeys: onlyWithKeys,
      interactiveOnly: interactiveOnly,
    );
    return UiTreeCapture(elements, uiTreeSignature(elements));
  }

  /// Re-captures until two consecutive trees agree, then returns the settled
  /// tree. Bounded by [timeout] so an animating Client cannot stall a caller.
  ///
  /// When the tree never settles, the last capture is returned with
  /// `settled: false` so a caller can tell quiescence from a truncated wait.
  Future<UiTreeCapture> captureSettledTree({
    String? filter,
    String? within,
    bool includeBounds = true,
    bool onlyWithKeys = false,
    bool interactiveOnly = false,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stopwatch = Stopwatch()..start();
    var previous = await captureTree(
      filter: filter,
      within: within,
      includeBounds: includeBounds,
      onlyWithKeys: onlyWithKeys,
      interactiveOnly: interactiveOnly,
    );
    while (stopwatch.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final next = await captureTree(
        filter: filter,
        within: within,
        includeBounds: includeBounds,
        onlyWithKeys: onlyWithKeys,
        interactiveOnly: interactiveOnly,
      );
      if (next.signature == previous.signature) {
        return UiTreeCapture(next.elements, next.signature, settled: true);
      }
      previous = next;
    }
    return UiTreeCapture(
      previous.elements,
      previous.signature,
      settled: false,
    );
  }

  /// Enumerates the runtime types that are rendered in the Client tree.
  ///
  /// Fails closed when the Client cannot answer: an absence claim without a
  /// census would be a false success.
  Future<UiTypeCensus> typeCensus({String? within}) async {
    final isolateId = await _discoverIsolateId('ext.sanad_client.inspect_ui');
    final result =
        await _callRpc('ext.sanad_client.inspect_ui', {
          'isolateId': isolateId,
          'typeCensus': 'true',
          if (within != null) 'within': within,
        }) as Map<String, dynamic>?;
    final types = (result?['types'] as List?)?.whereType<String>().toSet();
    if (types == null) {
      throw const _DriverException(
        'This Client cannot enumerate rendered widget types, so an absence '
        'claim cannot be verified. Rebuild the driver entry point or wait on a '
        'widget key instead.',
      );
    }
    return UiTypeCensus(
      types,
      truncated: result?['truncated'] == true,
      visitedElements: (result?['visited_elements'] as num?)?.toInt() ?? 0,
    );
  }

  /// Returns the active browser authentication URL from this exact driver VM.
  Future<String> authUrl() async {
    final isolateId = await _discoverIsolateId('ext.sanad_client.auth_url');
    final result = await _callRpc('ext.sanad_client.auth_url', {
      'isolateId': isolateId,
    }) as Map<String, dynamic>?;
    final value = result?['auth_url'];
    if (result?['status'] != 'ok' || value is! String) {
      throw const _DriverException(
        'The client returned no active authentication URL.',
      );
    }

    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const _DriverException(
        'The client returned an invalid authentication URL.',
      );
    }
    return value;
  }

  /// Find UI elements matching key, text, type, or query.
  Future<List<UiElement>> findElements({
    String? key,
    String? text,
    String? type,
    String? query,
    String? within,
    bool interactiveOnly = false,
  }) async {
    final all = await snapshot(
      includeBounds: true,
      within: within,
      interactiveOnly: interactiveOnly,
    );
    return all
        .where(
          (el) => el.matches(
            keyFilter: key,
            textFilter: text,
            typeFilter: type,
            query: query,
          ),
        )
        .toList();
  }

  /// Taps an element resolved by key, text, type, or coordinates.
  ///
  /// [verify] observes the widget tree around the tap. Observation alone is not
  /// an assertion: unless [strictVerify], [expect], or [expectAbsent] is
  /// supplied, an unchanged tree still reports success so an inert control can
  /// be tapped without turning the command into a failure. Strict mode turns
  /// that same condition into an error.
  ///
  /// The baseline tree is captured after [revealTarget] has scrolled the target
  /// into view, so scroll-induced bound changes are never mistaken for the
  /// tap's effect.
  Future<DriverActionResult> tap({
    String? key,
    String? text,
    String? type,
    String? within,
    int index = 0,
    double? x,
    double? y,
    Duration timeout = const Duration(seconds: 30),
    Duration postDelay = const Duration(milliseconds: 300),
    String? expect,
    String? expectAbsent,
    bool verify = true,
    bool strictVerify = false,
    Duration verifyTimeout = defaultVerifyTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    final targetDesc = key ?? text ?? type ?? '($x, $y)';
    final withinDesc = within != null ? ' (within $within)' : '';
    final strict = strictVerify || expect != null || expectAbsent != null;
    final selectorTarget = key != null || text != null || type != null;

    // Scrolling is part of resolving the target, not part of the tap: reveal
    // first so the captured baseline already reflects the new scroll offset.
    // A coordinate tap has nothing to reveal, so it never claims the caveat.
    final revealAttempted = verify && selectorTarget;
    var revealed = false;
    if (revealAttempted) {
      revealed = await revealTarget(
        key: key,
        text: text,
        type: type,
        within: within,
        index: index,
      );
    }

    // Verification observes the whole tree: a scoped tap may legitimately
    // change widgets outside its selector scope.
    final before = verify ? await captureTree() : null;

    Object? extensionError;
    Map<String, dynamic>? res;
    try {
      final isolateId = await _discoverIsolateId('ext.sanad_client.tap');
      res =
          await _callRpc('ext.sanad_client.tap', {
            'isolateId': isolateId,
            if (key != null) 'key': key,
            if (text != null) 'text': text,
            if (type != null) 'type': type,
            if (within != null) 'within': within,
            if (index > 0) 'index': index.toString(),
            if (x != null) 'x': x.toString(),
            if (y != null) 'y': y.toString(),
          }) as Map<String, dynamic>?;
    } catch (error) {
      extensionError = error;
    }

    if (res == null || res['status'] != 'ok') {
      stopwatch.stop();
      // Scoped, indexed, and coordinate actions must never degrade to an
      // unscoped finder because that could tap a different widget.
      return DriverActionResult(
        success: false,
        action: 'tap',
        message:
            'Failed to tap $targetDesc$withinDesc: ${extensionError == null ? "extension returned no result" : _conciseError(extensionError)}',
        duration: stopwatch.elapsed,
        targetKey: key,
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }

    if (postDelay > Duration.zero) {
      await Future<void>.delayed(postDelay);
    }

    final tappedAt = res['tapped_at'];
    final tappedX = tappedAt is Map ? (tappedAt['x'] as num?)?.round() : null;
    final tappedY = tappedAt is Map ? (tappedAt['y'] as num?)?.round() : null;

    if (before == null) {
      stopwatch.stop();
      return DriverActionResult(
        success: true,
        action: 'tap',
        message: 'Tapped $targetDesc$withinDesc at ($tappedX, $tappedY)',
        data: res,
        duration: stopwatch.elapsed,
        targetKey: key,
        x: tappedX,
        y: tappedY,
        // Verification was not requested, so no channel produced a verdict.
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }

    final outcome = await _awaitPostCondition(
      before: before,
      expect: expect,
      expectAbsent: expectAbsent,
      window: verifyTimeout,
    );

    stopwatch.stop();
    final revealedNote = !revealAttempted || revealed
        ? ''
        : revealUnavailableNote;
    if (!outcome.passed) {
      final expectation = expect != null
          ? 'expected $expect to be present'
          : expectAbsent != null
          ? 'expected $expectAbsent to be gone'
          : 'the widget tree did not change';
      if (!strict) {
        return DriverActionResult(
          success: true,
          action: 'tap',
          message:
              'Tapped $targetDesc$withinDesc at ($tappedX, $tappedY); '
              'tap dispatched; no observable change within '
              '${verifyTimeout.inMilliseconds}ms. The tap is not idempotent: '
              'do not retry blindly. Pass --verify or --expect <key> to make '
              'this a failure.$revealedNote',
          data: res,
          duration: stopwatch.elapsed,
          targetKey: key,
          x: tappedX,
          y: tappedY,
          verification: UiVerification.noObservableChange,
          generation: _nextGeneration(),
        );
      }
      return DriverActionResult(
        success: false,
        action: 'tap',
        message:
            'tap dispatched; no observable change within '
            '${verifyTimeout.inMilliseconds}ms: $expectation. '
            'The target may be offstage, obscured, or inert; the tap was '
            'dispatched exactly once, so do not retry blindly. Pass '
            '--expect <key> to assert the intended outcome, --no-verify to '
            'accept a deliberate no-op, or navigate first.$revealedNote',
        data: res,
        duration: stopwatch.elapsed,
        targetKey: key,
        x: tappedX,
        y: tappedY,
        // The same physical outcome reports the same channel with or without
        // --verify; only success and the exit status differ.
        verification: UiVerification.noObservableChange,
        generation: _nextGeneration(),
      );
    }

    return DriverActionResult(
      success: true,
      action: 'tap',
      message:
          'Tapped $targetDesc$withinDesc at ($tappedX, $tappedY)$revealedNote',
      data: res,
      duration: stopwatch.elapsed,
      targetKey: key,
      x: tappedX,
      y: tappedY,
      verification: outcome.verification,
      generation: _nextGeneration(),
    );
  }

  /// Scrolls a selector into view without dispatching a pointer event.
  ///
  /// Returns false when the Client does not register
  /// `ext.sanad_client.reveal`; callers then observe the tree without a reveal
  /// guarantee instead of failing the action.
  Future<bool> revealTarget({
    String? key,
    String? text,
    String? type,
    String? within,
    int index = 0,
  }) async {
    try {
      final isolateId = await _discoverIsolateId('ext.sanad_client.reveal');
      final result =
          await _callRpc('ext.sanad_client.reveal', {
            'isolateId': isolateId,
            if (key != null) 'key': key,
            if (text != null) 'text': text,
            if (type != null) 'type': type,
            if (within != null) 'within': within,
            if (index > 0) 'index': index.toString(),
          }) as Map<String, dynamic>?;
      return result?['revealed'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Enters text into an input field and verifies the observable effect.
  ///
  /// Verification prefers the field's rendered text (which is compared, never
  /// echoed). When the Client hides the value (obscured field), an observable
  /// widget-tree change is required instead, even when the field was selected by
  /// key.
  ///
  /// The baseline tree is captured after the focus tap, so focus-induced
  /// scrolling is never mistaken for the entered text's effect.
  Future<DriverActionResult> enterText(
    String text, {
    String? key,
    bool tapFirst = true,
    Duration timeout = const Duration(seconds: 30),
    Duration postDelay = const Duration(milliseconds: 300),
    bool verify = true,
    Duration verifyTimeout = defaultVerifyTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();

    if (key != null && tapFirst) {
      final focusResult = await tap(
        key: key,
        timeout: timeout,
        postDelay: const Duration(milliseconds: 150),
        verify: false,
      );
      if (!focusResult.success) {
        stopwatch.stop();
        return DriverActionResult(
          success: false,
          action: 'enter_text',
          message: 'Failed to focus $key: ${focusResult.message}',
          duration: stopwatch.elapsed,
          targetKey: key,
          verification: UiVerification.none,
        );
      }
    }

    UiTreeCapture? before;
    String? observedBefore;
    if (verify) {
      try {
        before = await captureTree();
        if (key != null) {
          observedBefore = uiElementByKey(before.elements, key)?.text;
        }
      } catch (_) {
        before = null;
      }
    }

    Object? extensionError;
    try {
      final isolateId = await _discoverIsolateId('ext.sanad_client.enter_text');
      final response = await _callRpc('ext.sanad_client.enter_text', {
        'isolateId': isolateId,
        'text': text,
        if (key != null) 'key': key,
      }) as Map<String, dynamic>?;
      if (response?['status'] != 'ok') {
        extensionError = const _DriverException(
          'extension returned no result',
        );
      }
    } catch (error) {
      extensionError = error;
    }

    if (extensionError != null) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'enter_text',
        message:
            'Failed entering text${key == null ? '' : ' into $key'}: ${_conciseError(extensionError)}',
        duration: stopwatch.elapsed,
        targetKey: key,
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }

    if (postDelay > Duration.zero) {
      await Future<void>.delayed(postDelay);
    }

    final message = key == null
        ? 'Successfully entered text into the focused field'
        : 'Successfully entered text into $key';

    if (before == null) {
      stopwatch.stop();
      return DriverActionResult(
        success: true,
        action: 'enter_text',
        message: message,
        duration: stopwatch.elapsed,
        targetKey: key,
        // --no-verify: the entry was dispatched without an observation.
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }

    final deadline = Stopwatch()..start();
    UiTreeCapture latest = before;
    UiVerification? verifiedBy;
    // A field whose rendered text is absent from the inspection is unobservable
    // (obscured, or an empty non-obscured field that emits no text). For those
    // the only available evidence is an observable tree change.
    final fieldValueUnobservable = key != null && observedBefore == null;
    while (true) {
      latest = await captureTree();
      if (fieldValueUnobservable) {
        if (latest.signature != before.signature) {
          verifiedBy = UiVerification.tree;
          break;
        }
      } else if (key != null) {
        final observedAfter = uiElementByKey(latest.elements, key)?.text;
        if (observedAfter != null && observedAfter == text) {
          verifiedBy = UiVerification.text;
          break;
        }
        if (observedAfter != observedBefore) {
          verifiedBy = UiVerification.text;
          break;
        }
      } else if (latest.signature != before.signature) {
        verifiedBy = UiVerification.tree;
        break;
      }
      if (deadline.elapsed >= verifyTimeout) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    stopwatch.stop();
    if (verifiedBy == null) {
      return DriverActionResult(
        success: false,
        action: 'enter_text',
        message:
            'enter-text reported success but had no observable effect on '
            '${key ?? 'the focused field'} within ${verifyTimeout.inMilliseconds}ms'
            '${fieldValueUnobservable ? ' (the field value is not exposed, so the widget tree was checked instead and it did not change)' : ''}: '
            'the field may not be editable or focus was lost; '
            'pass --no-verify for intentionally unobservable fields.',
        duration: stopwatch.elapsed,
        targetKey: key,
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }

    return DriverActionResult(
      success: true,
      action: 'enter_text',
      message: message,
      duration: stopwatch.elapsed,
      targetKey: key,
      verification: verifiedBy,
      generation: _nextGeneration(),
    );
  }

  /// Scrolls a scrollable container or scrolls until target widget is visible.
  ///
  /// `untilVisibleKey` is driven by bounded offset scrolling plus tree probes,
  /// so an unreachable or offstage target fails fast instead of hanging.
  Future<DriverActionResult> scroll({
    String? key,
    double dx = 0.0,
    double dy = -300.0,
    Duration duration = const Duration(milliseconds: 300),
    String? to,
    String? untilVisibleKey,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final stopwatch = Stopwatch()..start();
    if (to != null && to != 'top' && to != 'bottom') {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'scroll',
        message: 'Scroll target must be top or bottom',
        duration: stopwatch.elapsed,
        verification: UiVerification.none,
      );
    }
    if (to != null && untilVisibleKey != null) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'scroll',
        message: 'Scroll cannot combine to with until-visible',
        duration: stopwatch.elapsed,
        verification: UiVerification.none,
      );
    }

    if (untilVisibleKey != null) {
      return _scrollUntilVisible(
        scrollableKey: key,
        targetKey: untilVisibleKey,
        dx: dx,
        dy: dy,
        timeout: timeout,
        stopwatch: stopwatch,
      );
    }

    try {
      final isolateId = await _discoverIsolateId('ext.sanad_client.scroll');
      final res = await _callRpc('ext.sanad_client.scroll', {
        'isolateId': isolateId,
        if (key != null) 'key': key,
        'dx': dx.toString(),
        'dy': dy.toString(),
        if (to != null) 'to': to,
      }) as Map<String, dynamic>?;

      if (res != null && res['status'] == 'ok') {
        stopwatch.stop();
        return DriverActionResult(
          success: true,
          action: 'scroll',
          message:
              'Scrolled to offset ${res["offset"]} (min: ${res["min_extent"]}, max: ${res["max_extent"]})',
          data: res,
          duration: stopwatch.elapsed,
          targetKey: key,
          // A fixed-offset scroll makes no post-condition claim; the caller
          // observes the result.
          verification: UiVerification.none,
          generation: _nextGeneration(),
        );
      }
      throw const _DriverException('extension returned no result');
    } catch (error) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'scroll',
        message: 'Scroll failed: ${_conciseError(error)}',
        duration: stopwatch.elapsed,
        targetKey: key,
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }
  }

  Future<DriverActionResult> _scrollUntilVisible({
    required String? scrollableKey,
    required String targetKey,
    required double dx,
    required double dy,
    required Duration timeout,
    required Stopwatch stopwatch,
  }) async {
    final stepDy = dy == 0 ? -300.0 : dy;
    final deadline = Stopwatch()..start();
    var previousSignature = '';
    var attempts = 0;

    try {
      while (true) {
        final probe = await captureTree();
        final target = uiElementByKey(probe.elements, targetKey);
        if (target != null && target.bounds != null) {
          stopwatch.stop();
          return DriverActionResult(
            success: true,
            action: 'scroll',
            message:
                'Scrolled until $targetKey visible after $attempts scroll step(s)',
            data: {
              'attempts': attempts,
              'bounds': target.bounds!.toJson(),
            },
            duration: stopwatch.elapsed,
            targetKey: targetKey,
            verification: UiVerification.tree,
            generation: _nextGeneration(),
          );
        }
        if (target != null && target.bounds == null) {
          stopwatch.stop();
          return DriverActionResult(
            success: false,
            action: 'scroll',
            message:
                '$offstageTargetGuidance: $targetKey is mounted but has no '
                'rendered bounds.',
            duration: stopwatch.elapsed,
            targetKey: targetKey,
            verification: UiVerification.none,
            generation: _nextGeneration(),
          );
        }
        if (probe.signature == previousSignature && attempts > 0) {
          stopwatch.stop();
          return DriverActionResult(
            success: false,
            action: 'scroll',
            message:
                '$offstageTargetGuidance: scrolling no longer changes the tree '
                'and $targetKey never became visible.',
            duration: stopwatch.elapsed,
            targetKey: targetKey,
            verification: UiVerification.none,
            generation: _nextGeneration(),
          );
        }
        if (deadline.elapsed >= timeout) {
          stopwatch.stop();
          return DriverActionResult(
            success: false,
            action: 'scroll',
            message:
                '$offstageTargetGuidance: $targetKey was not visible within '
                '${timeout.inSeconds}s.',
            duration: stopwatch.elapsed,
            targetKey: targetKey,
            verification: UiVerification.none,
            generation: _nextGeneration(),
          );
        }
        previousSignature = probe.signature;

        final isolateId = await _discoverIsolateId('ext.sanad_client.scroll');
        await _callRpc('ext.sanad_client.scroll', {
          'isolateId': isolateId,
          if (scrollableKey != null) 'key': scrollableKey,
          'dx': dx.toString(),
          'dy': stepDy.toString(),
        });
        attempts++;
      }
    } catch (error) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'scroll',
        message:
            '$offstageTargetGuidance: $targetKey could not be scrolled into view '
            '(${_conciseError(error)}).',
        duration: stopwatch.elapsed,
        targetKey: targetKey,
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }
  }

  /// Waits for a widget to be present (or absent if [absent] is true).
  ///
  /// Driven by bounded tree probes rather than the Flutter Driver extension, so
  /// waiting does not depend on animation-free frame synchronization.
  ///
  /// A `--type` query is checked against the inspected tree for presence. An
  /// absence claim is checked against the rendered type census instead, because
  /// the inspected tree omits unkeyed widgets that carry no text, tooltip, or
  /// interaction (for example `CircularProgressIndicator`); treating those as
  /// absent would be a false success.
  ///
  /// A complete census that still contains the type is not a verdict: a spinner
  /// that is rendered now may legitimately finish later, so the poll continues
  /// until the deadline and only then fails, naming the census as its evidence
  /// instead of reporting a bare timeout. [noWait] judges the first probe
  /// immediately for callers that need a fail-fast answer.
  Future<DriverActionResult> waitFor({
    String? key,
    String? text,
    String? type,
    bool absent = false,
    Duration timeout = const Duration(seconds: 30),
    bool noWait = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    final target = key ?? text ?? type ?? '';
    final claim = absent ? 'absent' : 'present';
    var probes = 0;
    var censusChecked = false;

    // A `--no-wait` verdict is one probe, not a wait, and the diagnostic must
    // not pretend otherwise.
    String waitedLabel() => noWait
        ? 'a single check (${stopwatch.elapsedMilliseconds}ms)'
        : '${stopwatch.elapsedMilliseconds}ms';
    bool deadlineReached() => noWait || stopwatch.elapsed >= timeout;

    try {
      while (true) {
        probes++;
        if (type != null && absent) {
          final census = await typeCensus();
          if (census.truncated) {
            stopwatch.stop();
            // Truncation is not a timeout: no amount of waiting can complete a
            // walk the Client bounded on purpose, so the diagnostic must name
            // the census instead of implying a slow Client.
            final bound = census.visitedElements > 0
                ? ' at its ${census.visitedElements}-element bound'
                : '';
            return DriverActionResult(
              success: false,
              action: 'wait_for',
              message:
                  'type census truncated$bound: cannot prove that $type is '
                  'absent. Wait on a widget key or text instead.',
              data: {
                'waited_ms': stopwatch.elapsedMilliseconds,
                'absent': absent,
                'census_truncated': true,
                if (census.visitedElements > 0)
                  'census_visited_elements': census.visitedElements,
              },
              duration: stopwatch.elapsed,
              targetKey: key,
              verification: UiVerification.none,
              generation: _nextGeneration(),
            );
          }
          if (!census.contains(type)) {
            stopwatch.stop();
            return DriverActionResult(
              success: true,
              action: 'wait_for',
              message:
                  '$target is absent (waited ${stopwatch.elapsedMilliseconds}ms, '
                  'proven by the rendered type census)',
              data: {
                'waited_ms': stopwatch.elapsedMilliseconds,
                'absent': absent,
                'evidence': 'type_census',
              },
              duration: stopwatch.elapsed,
              targetKey: key,
              verification: UiVerification.absent,
              generation: _nextGeneration(),
            );
          }
          // The type is still rendered. Absence can legitimately arrive later
          // (a spinner finishes), so keep polling and let the deadline produce
          // the evidence-bearing verdict rather than an early false failure.
          if (deadlineReached()) {
            stopwatch.stop();
            final hint = noWait
                ? ' `--no-wait` judged the first census only.'
                : ' Pass --no-wait to judge the first census instead of '
                      'waiting out --timeout.';
            return DriverActionResult(
              success: false,
              action: 'wait_for',
              message:
                  '$type is still rendered (proven by the rendered type '
                  'census) after ${waitedLabel()}; absence not observed.$hint',
              data: {
                'waited_ms': stopwatch.elapsedMilliseconds,
                'absent': absent,
                'evidence': 'type_census',
                'still_rendered': true,
                'probes': probes,
              },
              duration: stopwatch.elapsed,
              targetKey: key,
              verification: UiVerification.typeCensus,
              generation: _nextGeneration(),
            );
          }
        } else {
          final elements = await snapshot(includeBounds: false);
          final present = elements.any(
            (element) => element.matches(
              keyFilter: key,
              textFilter: text,
              typeFilter: type,
            ),
          );
          if (absent ? !present : present) {
            stopwatch.stop();
            return DriverActionResult(
              success: true,
              action: 'wait_for',
              message:
                  '$target is $claim '
                  '(waited ${stopwatch.elapsedMilliseconds}ms)',
              data: {
                'waited_ms': stopwatch.elapsedMilliseconds,
                'absent': absent,
              },
              duration: stopwatch.elapsed,
              targetKey: key,
              verification: absent ? UiVerification.absent : UiVerification.present,
              generation: _nextGeneration(),
            );
          }
          if (type != null && !absent && !censusChecked) {
            // A rendered type that the inspection omits would otherwise wait
            // out the full timeout and report a bare timeout for a widget that
            // is visibly on screen.
            censusChecked = true;
            final census = await typeCensus();
            if (!census.truncated && census.contains(type)) {
              stopwatch.stop();
              return DriverActionResult(
                success: false,
                action: 'wait_for',
                message:
                    '$type is still rendered (proven by the rendered type '
                    'census) after ${waitedLabel()}, but it is not inspected '
                    'because it carries no key, text, tooltip, or interaction. '
                    'Wait on its keyed ancestor or on visible text instead.',
                data: {
                  'waited_ms': stopwatch.elapsedMilliseconds,
                  'absent': absent,
                  'evidence': 'type_census',
                  'still_rendered': true,
                  'rendered_but_uninspected': true,
                },
                duration: stopwatch.elapsed,
                targetKey: key,
                verification: UiVerification.typeCensus,
                generation: _nextGeneration(),
              );
            }
          }
        }
        if (deadlineReached()) {
          stopwatch.stop();
          return DriverActionResult(
            success: false,
            action: 'wait_for',
            message: absent
                ? '$target is still present after ${waitedLabel()}; absence '
                      'not observed across $probes inspected-tree probe(s)'
                : '$target was not found after ${waitedLabel()}; presence '
                      'not observed across $probes inspected-tree probe(s)',
            data: {
              'waited_ms': stopwatch.elapsedMilliseconds,
              'absent': absent,
              'probes': probes,
            },
            duration: stopwatch.elapsed,
            targetKey: key,
            verification: UiVerification.none,
            generation: _nextGeneration(),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } catch (error) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'wait_for',
        message:
            'Wait failed for $target: ${_conciseError(error)} '
            '(waited ${stopwatch.elapsedMilliseconds}ms)',
        data: {'waited_ms': stopwatch.elapsedMilliseconds},
        duration: stopwatch.elapsed,
        targetKey: key,
        verification: UiVerification.none,
        generation: _nextGeneration(),
      );
    }
  }

  /// Captures a visual viewport screenshot and writes it as PNG.
  Future<File> screenshot({String? outputPath}) async {
    await _ensureDriverConnected();
    final bytes = await _driver!.screenshot();

    final runningFromClient =
        Directory.current.path.split(Platform.pathSeparator).last == 'client';
    final defaultDir = runningFromClient
        ? 'test/interactive/screenshots'
        : 'client/test/interactive/screenshots';
    final targetPath =
        outputPath ??
        '$defaultDir/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';

    final file = File(targetPath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Executes a sequence of declarative steps in a single connection session.
  ///
  /// [onProgress] is invoked after every step with the results so far so a
  /// caller can persist partial evidence; a wall-clock kill can then still
  /// report which steps completed.
  ///
  /// [defaultStepTimeout] is the recipe-wide deadline for steps that declare no
  /// `timeout_seconds`. It is the batch `--timeout`, so the caller's wall clock
  /// and the deadline enforced here come from the same option.
  Future<List<DriverActionResult>> runBatch(
    List<BatchStep> steps, {
    void Function(List<DriverActionResult> results)? onProgress,
    Duration? defaultStepTimeout,
  }) async {
    final results = <DriverActionResult>[];

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepTimeout = batchStepTimeout(step, defaultStepTimeout);
      final stepDelay = step.delayMs != null
          ? Duration(milliseconds: step.delayMs!)
          : const Duration(milliseconds: 300);
      final stepVerifyTimeout = stepTimeout < defaultVerifyTimeout
          ? stepTimeout
          : defaultVerifyTimeout;

      switch (step.action.toLowerCase()) {
        case 'tap':
          final res = await tap(
            key: step.key,
            text: step.text,
            type: step.type,
            within: step.within,
            index: step.index ?? 0,
            x: step.x,
            y: step.y,
            timeout: stepTimeout,
            postDelay: stepDelay,
            expect: step.expect,
            expectAbsent: step.expectAbsent,
            verify: !step.noVerify,
            strictVerify: step.strictVerify,
            verifyTimeout: stepVerifyTimeout,
          );
          results.add(res);
          break;

        case 'enter_text':
        case 'entertext':
          final res = await enterText(
            step.text ?? '',
            key: step.key,
            timeout: stepTimeout,
            postDelay: stepDelay,
            verify: !step.noVerify,
            verifyTimeout: stepVerifyTimeout,
          );
          results.add(res);
          break;

        case 'scroll':
          final res = await scroll(
            key: step.key,
            dx: step.dx ?? 0.0,
            dy: step.dy ?? -300.0,
            to: step.to,
            untilVisibleKey: step.untilVisibleKey,
            timeout: stepTimeout,
          );
          results.add(res);
          break;

        case 'wait_for':
        case 'waitfor':
          final res = await waitFor(
            key: step.key,
            text: step.text,
            type: step.type,
            absent: step.absent,
            timeout: stepTimeout,
            noWait: step.noWait,
          );
          results.add(res);
          break;

        case 'sleep':
        case 'delay':
          final ms = step.sleepMs ?? 1000;
          await Future<void>.delayed(Duration(milliseconds: ms));
          results.add(
            DriverActionResult(
              success: true,
              action: 'sleep',
              message: 'Slept for ${ms}ms',
              duration: Duration(milliseconds: ms),
              verification: UiVerification.none,
            ),
          );
          break;

        case 'screenshot':
          final file = await screenshot(outputPath: step.out);
          results.add(
            DriverActionResult(
              success: true,
              action: 'screenshot',
              message: 'Screenshot saved to ${file.path}',
              data: {'file_path': file.path},
              duration: Duration.zero,
              verification: UiVerification.none,
            ),
          );
          break;

        case 'snapshot':
          final capture = step.fresh
              ? await captureSettledTree(timeout: stepTimeout)
              : await captureTree();
          results.add(
            DriverActionResult(
              success: true,
              action: 'snapshot',
              message: 'Extracted ${capture.elements.length} UI elements',
              data: {
                'count': capture.elements.length,
                'signature': capture.signature,
              },
              duration: Duration.zero,
              // A snapshot step observes the tree but asserts no post-condition.
              verification: UiVerification.none,
              generation: _nextGeneration(),
            ),
          );
          break;

        case 'message_bodies':
          final elements = await snapshot(onlyWithKeys: true);
          final messageBodies = elements
              .where(
                (element) =>
                    element.key?.startsWith('user_message_body:') == true ||
                    element.key?.startsWith('assistant_message_body:') == true,
              )
              .toList();
          const maxMessageBodies = 50;
          final bounded = messageBodies.length > maxMessageBodies
              ? messageBodies.sublist(messageBodies.length - maxMessageBodies)
              : messageBodies;
          results.add(
            DriverActionResult(
              success: true,
              action: 'message_bodies',
              message: 'Captured ${bounded.length} message bodies',
              data: {
                'count': messageBodies.length,
                'elements': bounded.map((element) => element.toJson()).toList(),
                'truncated': messageBodies.length > bounded.length,
              },
              duration: Duration.zero,
              verification: UiVerification.none,
              generation: _nextGeneration(),
            ),
          );
          break;

        default:
          results.add(
            DriverActionResult(
              success: false,
              action: step.action,
              message: 'Unknown batch action: ${step.action}',
              duration: Duration.zero,
              verification: UiVerification.none,
            ),
          );
      }

      onProgress?.call(List.unmodifiable(results));

      if (results.isNotEmpty &&
          !results.last.success &&
          !step.continueOnError) {
        break;
      }
    }

    return results;
  }

  /// Polls the tree until the post-condition holds or the window expires.
  Future<_PostConditionOutcome> _awaitPostCondition({
    required UiTreeCapture before,
    required String? expect,
    required String? expectAbsent,
    required Duration window,
  }) async {
    final stopwatch = Stopwatch()..start();
    final hasExplicitExpectation = expect != null || expectAbsent != null;
    while (true) {
      final probe = await captureTree();
      final expectPresent =
          expect == null || uiElementByKey(probe.elements, expect) != null;
      final expectAbsentSatisfied =
          expectAbsent == null ||
          uiElementByKey(probe.elements, expectAbsent) == null;
      if (hasExplicitExpectation) {
        if (expectPresent && expectAbsentSatisfied) {
          return const _PostConditionOutcome(
            passed: true,
            verification: UiVerification.key,
          );
        }
      } else if (probe.signature != before.signature) {
        return const _PostConditionOutcome(
          passed: true,
          verification: UiVerification.tree,
        );
      }
      if (stopwatch.elapsed >= window) {
        return const _PostConditionOutcome(
          passed: false,
          verification: UiVerification.none,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  int? _nextGeneration() => generationStore?.next();

  Future<String> _discoverIsolateId(String requiredExtension) async {
    final cached = _isolateByExtension[requiredExtension];
    if (cached != null) return cached;
    final vm = await _callRpc('getVM') as Map<String, dynamic>?;
    final isolates = vm?['isolates'] as List? ?? const [];
    for (final isolateRef in isolates) {
      final id = (isolateRef as Map)['id'] as String?;
      if (id == null) continue;
      final isolate =
          await _callRpc('getIsolate', {
            'isolateId': id,
          }) as Map<String, dynamic>?;
      final extensions = (isolate?['extensionRPCs'] as List? ?? const [])
          .whereType<String>();
      if (extensions.contains(requiredExtension)) {
        _isolateByExtension[requiredExtension] = id;
        return id;
      }
    }
    throw StateError(
      'No Flutter isolate exposes $requiredExtension. '
      'Launch the client through sanad-dev run --driver.',
    );
  }

  /// Closes all active connections gracefully.
  Future<void> close() async {
    try {
      await _socketSub?.cancel();
    } catch (_) {}
    try {
      await _socket?.close();
    } catch (_) {}
    try {
      await _driver?.close();
    } catch (_) {}
  }
}

class _PostConditionOutcome {
  const _PostConditionOutcome({
    required this.passed,
    required this.verification,
  });

  final bool passed;
  final UiVerification verification;
}
