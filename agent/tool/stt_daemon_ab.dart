// G5 A/B probe: speaks a WAV file into the running daemon over the same
// dictation socket the client uses, then prints every transcript event with the
// wall-clock time it arrived.
//
// It proves the streaming contract end to end (daemon → session → engine →
// socket): a streaming entry publishes `dictation_partial` while audio is still
// being sent, while a batch entry publishes only one `dictation_final` after the
// stop command.
//
// Usage:
//   fvm dart run tool/stt_daemon_ab.dart <port> <model_id> <wav> [sanad_home]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: stt_daemon_ab.dart <port> <model_id> <wav>');
    exit(64);
  }
  final port = int.parse(args[0]);
  final modelId = args[1];
  final home = args.length > 3
      ? args[3]
      : (Platform.environment['SANAD_HOME'] ??
            '${Platform.environment['HOME']}/.sanad-test');
  final pcm = _readWavPcm(args[2]);
  final audioMs = pcm.length ~/ 2 * 1000 ~/ 16000;

  final socket = await WebSocket.connect(
    'ws://127.0.0.1:$port/ws?type=dictation',
    headers: {'x-sanad-local-token': _localToken(home)},
  );
  final clock = Stopwatch()..start();
  var partials = 0;
  var finals = 0;
  var firstPartialMs = -1;
  var started = false;
  final done = Completer<void>();

  socket.listen((message) {
    if (message is! String) return;
    final event = jsonDecode(message) as Map<String, dynamic>;
    final name = event['event'] as String? ?? '';
    final at = clock.elapsedMilliseconds;
    switch (name) {
      case 'stt_status':
        final selected = event['selected'];
        final models = (event['models'] as List?)?.length ?? 0;
        stdout.writeln('[${at}ms] status selected=$selected models=$models');
        if (!started) {
          started = true;
          socket.add(jsonEncode({'event': 'start'}));
        }
      case 'dictation_ready':
        stdout.writeln('[${at}ms] ready load_ms=${event['load_ms']}');
        unawaited(_stream(socket, pcm));
      case 'dictation_partial':
        partials++;
        if (firstPartialMs < 0) firstPartialMs = at;
        stdout.writeln('[${at}ms] partial: ${event['text']}');
      case 'dictation_final':
        finals++;
        stdout.writeln(
          '[${at}ms] final[${event['seq']}]: ${event['text']}',
        );
      case 'dictation_done':
        stdout.writeln('[${at}ms] done segments=${event['segments']}');
        if (!done.isCompleted) done.complete();
      case 'dictation_error':
        stderr.writeln('[${at}ms] error ${event['code']}: ${event['message']}');
        if (!done.isCompleted) done.complete();
    }
  });

  socket.add(jsonEncode({'event': 'select', 'model_id': modelId}));
  socket.add(jsonEncode({'event': 'status'}));

  await done.future.timeout(const Duration(seconds: 240), onTimeout: () {});
  stdout.writeln(
    'summary: audio=${audioMs}ms partials=$partials finals=$finals '
    'first_partial_after_start=${firstPartialMs}ms '
    'wall=${clock.elapsedMilliseconds}ms',
  );
  await socket.close();
  exit(0);
}

/// The owner-only local credential the daemon bound at start.
String _localToken(String home) {
  final file = File('$home/.local_token');
  if (!file.existsSync()) {
    stderr.writeln('missing local token at ${file.path}');
    exit(77);
  }
  return file.readAsStringSync().trim();
}

/// Sends the utterance in 100 ms frames, paced like a live microphone.
Future<void> _stream(WebSocket socket, Uint8List pcm) async {
  const chunkBytes = 3200; // 100 ms of 16 kHz mono PCM16
  for (var offset = 0; offset < pcm.length; offset += chunkBytes) {
    final end = (offset + chunkBytes).clamp(0, pcm.length);
    socket.add(Uint8List.sublistView(pcm, offset, end));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  socket.add(jsonEncode({'event': 'stop'}));
}

Uint8List _readWavPcm(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      return Uint8List.sublistView(bytes, offset + 8, offset + 8 + size);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk in $path');
}
