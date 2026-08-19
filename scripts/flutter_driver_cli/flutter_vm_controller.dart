import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:flutter_driver/flutter_driver.dart';

import 'models.dart';

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

/// Controller that coordinates FlutterDriver actions and custom VM service extensions.
class FlutterVmController {
  final String serviceUrl;
  final String wsUrl;
  FlutterDriver? _driver;
  WebSocket? _socket;
  StreamSubscription? _socketSub;
  final Map<int, Completer<dynamic>> _pendingRpc = {};
  int _requestId = 100;

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
      return await completer.future.timeout(const Duration(seconds: 10));
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
  Future<DriverActionResult> tap({
    String? key,
    String? text,
    String? type,
    String? within,
    int index = 0,
    double? x,
    double? y,
    Duration timeout = const Duration(seconds: 10),
    Duration postDelay = const Duration(milliseconds: 300),
  }) async {
    final stopwatch = Stopwatch()..start();

    // 1. Try service extension
    Object? extensionError;
    try {
      final isolateId = await _discoverIsolateId('ext.sanad_client.tap');
      final res = await _callRpc('ext.sanad_client.tap', {
        'isolateId': isolateId,
        if (key != null) 'key': key,
        if (text != null) 'text': text,
        if (type != null) 'type': type,
        if (within != null) 'within': within,
        if (index > 0) 'index': index.toString(),
        if (x != null) 'x': x.toString(),
        if (y != null) 'y': y.toString(),
      }) as Map<String, dynamic>?;

      if (res != null && res['status'] == 'ok') {
        if (postDelay > Duration.zero) {
          await Future<void>.delayed(postDelay);
        }
        stopwatch.stop();
        final targetDesc = key ?? text ?? type ?? '($x, $y)';
        final withinDesc = within != null ? ' (within $within)' : '';
        return DriverActionResult(
          success: true,
          action: 'tap',
          message:
              'Successfully tapped $targetDesc$withinDesc (at ${res["tapped_at"]})',
          data: res,
          duration: stopwatch.elapsed,
        );
      }
    } catch (error) {
      extensionError = error;
    }

    // Scoped, indexed, and coordinate actions must never degrade to an
    // unscoped finder because that could tap a different widget.
    if (within != null || index != 0 || x != null || y != null) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'tap',
        message:
            'Failed to tap the requested target: ${extensionError == null ? "extension returned no result" : _conciseError(extensionError)}',
        duration: stopwatch.elapsed,
      );
    }

    // 2. Fallback to FlutterDriver for simple exact selectors.
    await _ensureDriverConnected();
    final finder = _resolveFinder(key: key, text: text, type: type);

    try {
      await _driver!.runUnsynchronized(() async {
        await _driver!.waitFor(finder, timeout: timeout);
        await _driver!.tap(finder, timeout: timeout);
        if (postDelay > Duration.zero) {
          await Future<void>.delayed(postDelay);
        }
      });
      stopwatch.stop();
      return DriverActionResult(
        success: true,
        action: 'tap',
        message: 'Successfully tapped ${key ?? text ?? type}',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'tap',
        message: 'Failed to tap ${key ?? text ?? type}: ${_conciseError(e)}',
        duration: stopwatch.elapsed,
      );
    }
  }

  /// Enters text into an input field. If [key] is supplied, taps it first to focus.
  Future<DriverActionResult> enterText(
    String text, {
    String? key,
    bool tapFirst = true,
    Duration timeout = const Duration(seconds: 10),
    Duration postDelay = const Duration(milliseconds: 300),
  }) async {
    final stopwatch = Stopwatch()..start();

    if (key != null && tapFirst) {
      final focusResult = await tap(
        key: key,
        timeout: timeout,
        postDelay: const Duration(milliseconds: 150),
      );
      if (!focusResult.success) {
        stopwatch.stop();
        return DriverActionResult(
          success: false,
          action: 'enter_text',
          message: 'Failed to focus $key: ${focusResult.message}',
          duration: stopwatch.elapsed,
        );
      }
    }

    await _ensureDriverConnected();
    try {
      await _driver!.runUnsynchronized(() async {
        await _driver!.enterText(text, timeout: timeout);
        if (postDelay > Duration.zero) {
          await Future<void>.delayed(postDelay);
        }
      });
      stopwatch.stop();
      return DriverActionResult(
        success: true,
        action: 'enter_text',
        message: key == null
            ? 'Successfully entered text into the focused field'
            : 'Successfully entered text into $key',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'enter_text',
        message: 'Failed entering text: ${_conciseError(e)}',
        duration: stopwatch.elapsed,
      );
    }
  }

  /// Scrolls a scrollable container or scrolls until target widget is visible.
  Future<DriverActionResult> scroll({
    String? key,
    double dx = 0.0,
    double dy = -300.0,
    Duration duration = const Duration(milliseconds: 300),
    String? to,
    String? untilVisibleKey,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final stopwatch = Stopwatch()..start();
    if (to != null && to != 'top' && to != 'bottom') {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'scroll',
        message: 'Scroll target must be top or bottom',
        duration: stopwatch.elapsed,
      );
    }
    if (to != null && untilVisibleKey != null) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'scroll',
        message: 'Scroll cannot combine to with until-visible',
        duration: stopwatch.elapsed,
      );
    }

    // Use the custom extension for offset scrolling. `scrollUntilVisible`
    // remains a FlutterDriver operation because it repeats until the target
    // is actually visible rather than reporting success after one offset.
    if (untilVisibleKey == null) {
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
          );
        }
      } catch (error) {
        if (to != null) {
          stopwatch.stop();
          return DriverActionResult(
            success: false,
            action: 'scroll',
            message: 'Scroll failed: ${_conciseError(error)}',
            duration: stopwatch.elapsed,
          );
        }
      }
    }

    // 2. Fallback to FlutterDriver
    await _ensureDriverConnected();
    try {
      await _driver!.runUnsynchronized(() async {
        if (untilVisibleKey != null) {
          final scrollable = key != null
              ? find.byValueKey(key)
              : find.byType('Scrollable');
          final item = find.byValueKey(untilVisibleKey);
          await _driver!.scrollUntilVisible(
            scrollable,
            item,
            dyScroll: dy,
            dxScroll: dx,
            timeout: timeout,
          );
        } else if (key != null) {
          final scrollable = find.byValueKey(key);
          await _driver!.scroll(scrollable, dx, dy, duration, timeout: timeout);
        } else {
          final scrollable = find.byType('Scrollable');
          await _driver!.scroll(scrollable, dx, dy, duration, timeout: timeout);
        }
      });
      stopwatch.stop();
      return DriverActionResult(
        success: true,
        action: 'scroll',
        message: untilVisibleKey != null
            ? 'Scrolled until $untilVisibleKey visible'
            : 'Scrolled (dx: $dx, dy: $dy)',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'scroll',
        message: 'Scroll failed: ${_conciseError(e)}',
        duration: stopwatch.elapsed,
      );
    }
  }

  /// Waits for a widget to be present (or absent if [absent] is true).
  Future<DriverActionResult> waitFor({
    String? key,
    String? text,
    String? type,
    bool absent = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final stopwatch = Stopwatch()..start();
    await _ensureDriverConnected();
    final finder = _resolveFinder(key: key, text: text, type: type);

    try {
      await _driver!.runUnsynchronized(() async {
        if (absent) {
          await _driver!.waitForAbsent(finder, timeout: timeout);
        } else {
          await _driver!.waitFor(finder, timeout: timeout);
        }
      });
      stopwatch.stop();
      return DriverActionResult(
        success: true,
        action: 'wait_for',
        message: '${key ?? text ?? type} is ${absent ? "absent" : "present"}',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return DriverActionResult(
        success: false,
        action: 'wait_for',
        message:
            'Timeout waiting for ${key ?? text ?? type} to be ${absent ? "absent" : "present"}: ${_conciseError(e)}',
        duration: stopwatch.elapsed,
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
  Future<List<DriverActionResult>> runBatch(List<BatchStep> steps) async {
    final results = <DriverActionResult>[];

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepTimeout = step.timeoutSeconds != null
          ? Duration(seconds: step.timeoutSeconds!)
          : const Duration(seconds: 15);
      final stepDelay = step.delayMs != null
          ? Duration(milliseconds: step.delayMs!)
          : const Duration(milliseconds: 300);

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
            ),
          );
          break;

        case 'snapshot':
          final elements = await snapshot();
          results.add(
            DriverActionResult(
              success: true,
              action: 'snapshot',
              message: 'Extracted ${elements.length} UI elements',
              data: {'count': elements.length},
              duration: Duration.zero,
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
            ),
          );
      }

      if (results.isNotEmpty &&
          !results.last.success &&
          !step.continueOnError) {
        break;
      }
    }

    return results;
  }

  SerializableFinder _resolveFinder({String? key, String? text, String? type}) {
    if (key != null && key.isNotEmpty) {
      return find.byValueKey(key);
    }
    if (text != null && text.isNotEmpty) {
      return find.text(text);
    }
    if (type != null && type.isNotEmpty) {
      return find.byType(type);
    }
    throw ArgumentError('Must provide at least one of: key, text, or type');
  }

  Future<String> _discoverIsolateId(String requiredExtension) async {
    final vm = await _callRpc('getVM') as Map<String, dynamic>?;
    final isolates = vm?['isolates'] as List? ?? const [];
    for (final isolateRef in isolates) {
      final id = (isolateRef as Map)['id'] as String?;
      if (id == null) continue;
      final isolate = await _callRpc('getIsolate', {
        'isolateId': id,
      }) as Map<String, dynamic>?;
      final extensions = (isolate?['extensionRPCs'] as List? ?? const [])
          .whereType<String>();
      if (extensions.contains(requiredExtension)) {
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
