/// A disconnected transport must not keep its per-session closures alive.
///
/// The local daemon registers one response emitter per session, and that
/// closure captures the Client's socket. It used to survive the socket: the
/// bridge dropped only the channel and device id on disconnect, so every session
/// the daemon had ever served kept pinning a closed socket (and the command
/// envelope its closure captured) for the life of the process. These tests pin
/// the release rule at the bridge owner: a channel-scoped emitter dies with its
/// own channel, an in-process emitter is untouched, and a reconnecting channel
/// keeps ownership of the emitter it registered.
library;

import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_session_channel.dart';
import 'package:test/test.dart';

class _FakeChannel implements PlatformSessionChannel {
  _FakeChannel(this.name);

  final String name;

  @override
  Future<void> sendProtocolEvent(
    String eventType,
    Map<String, dynamic> payload,
  ) async {}
}

void main() {
  late AgentStateDatabase state;
  late PlatformRuntimeBridge bridge;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    bridge = PlatformRuntimeBridge();
    bridge.attachResponseSink((_) {});
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
  });

  void registerChannelScoped(
    String sessionId,
    _FakeChannel channel,
  ) {
    bridge.registerSessionClient(sessionId, channel);
    bridge.registerSessionHandlers(
      sessionId,
      responseEmitter: (_) async {},
      channelScopedEmitter: true,
    );
  }

  test('a channel-scoped emitter is released with its own channel', () {
    final channel = _FakeChannel('client');
    registerChannelScoped('s-1', channel);
    expect(bridge.hasSessionResponseEmitter('s-1'), isTrue);

    bridge.unregisterChannel(channel);

    expect(
      bridge.hasSessionResponseEmitter('s-1'),
      isFalse,
      reason: 'the emitter captured the socket that just closed',
    );
  });

  test('an in-process emitter survives a channel disconnect', () {
    final channel = _FakeChannel('client');
    bridge.registerSessionClient('s-1', channel);
    bridge.registerSessionHandlers(
      's-1',
      responseEmitter: (_) async {},
    );

    bridge.unregisterChannel(channel);

    expect(
      bridge.hasSessionResponseEmitter('s-1'),
      isTrue,
      reason: 'the CLI transport still owns this session emitter',
    );
  });

  test('a reconnecting channel keeps the emitter it registered', () {
    final first = _FakeChannel('first');
    final second = _FakeChannel('second');
    registerChannelScoped('s-1', first);
    registerChannelScoped('s-1', second);

    bridge.unregisterChannel(first);

    expect(
      bridge.hasSessionResponseEmitter('s-1'),
      isTrue,
      reason: 'the live channel re-registered the emitter after the first one',
    );

    bridge.unregisterChannel(second);
    expect(bridge.hasSessionResponseEmitter('s-1'), isFalse);
  });

  test('only sessions of the closed channel are released', () {
    final local = _FakeChannel('local');
    final cloud = _FakeChannel('cloud');
    registerChannelScoped('s-local', local);
    registerChannelScoped('s-cloud', cloud);

    bridge.unregisterChannel(local);

    expect(bridge.hasSessionResponseEmitter('s-local'), isFalse);
    expect(bridge.hasSessionResponseEmitter('s-cloud'), isTrue);
  });

  test('unregistering the session releases every projection', () {
    final channel = _FakeChannel('client');
    registerChannelScoped('s-1', channel);
    bridge.unregisterSession('s-1');
    expect(bridge.hasSessionResponseEmitter('s-1'), isFalse);
  });
}
