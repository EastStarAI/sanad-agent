import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart';
import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart';

/// Coverage for the failure reason `sanad-dev restart client` reports.
///
/// It is a pure projection over discovered state, so no process, Home, or port
/// is involved.
void main() {
  AgentInstance agent({
    int port = 58085,
    String workspaceHash = '00000000',
    String? launcherId = 'launcher-a',
    String? runtimeNonce = 'nonce-a',
  }) => AgentInstance(
    port,
    workspaceHash,
    'default',
    launcherId: launcherId,
    runtimeNonce: runtimeNonce,
  );

  ClientInstance client({
    int port = 51000,
    int? pid = 4242,
    Map<String, String>? defines,
  }) => ClientInstance(
    port,
    '',
    '/repo/client',
    'macos',
    pid: pid,
    launchProfile: ClientLaunchProfile(
      compileArguments: const [],
      defines:
          defines ??
          {
            'LOCAL_GATEWAY_URL': 'http://127.0.0.1:58085',
            'SANAD_HOME': '/home/.sanad',
            'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
            'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
          },
    ),
  );

  RuntimeProcessState state({
    AgentInstance? matchedAgent,
    List<ClientInstance> ownedClients = const [],
    List<ClientInstance> crossOwned = const [],
    List<ClientInstance> ambiguous = const [],
    bool agentAmbiguous = false,
  }) => RuntimeProcessState(
    agent: matchedAgent,
    ownedClients: ownedClients,
    crossOwnedClients: crossOwned,
    ambiguousClients: ambiguous,
    agentAmbiguous: agentAmbiguous,
  );

  test('an owned Client needs no reason', () {
    final owned = client();
    expect(
      clientSelectionFailureReason(
        state(matchedAgent: agent(), ownedClients: [owned]),
        agentPort: 58085,
      ),
      isNull,
    );
  });

  test('a Client launched by another launcher names both identities', () {
    // This is the shape of the incident: the Client belonged to the live
    // launcher while the Agent on the port answered with another one. The old
    // message said only "no clients".
    final reason = clientSelectionFailureReason(
      state(
        matchedAgent: agent(
          launcherId: 'launcher-foreign',
          runtimeNonce: 'nonce-foreign',
        ),
        ambiguous: [client()],
      ),
      agentPort: 58085,
    );

    expect(reason, isNotNull);
    expect(reason, contains('VM port 51000'));
    expect(reason, contains('launcher-a'));
    expect(reason, contains('launcher-foreign'));
    expect(reason, contains('58085'));
  });

  test('a nonce mismatch names the nonces', () {
    final reason = clientSelectionFailureReason(
      state(
        matchedAgent: agent(runtimeNonce: 'nonce-foreign'),
        ambiguous: [client()],
      ),
      agentPort: 58085,
    );

    expect(reason, contains('runtime nonce nonce-a'));
    expect(reason, contains('nonce-foreign'));
  });

  test('an incomplete launch profile is named as such', () {
    final reason = clientSelectionFailureReason(
      state(
        matchedAgent: agent(),
        ambiguous: [
          client(defines: {'LOCAL_GATEWAY_URL': 'http://127.0.0.1:58085'}),
        ],
      ),
      agentPort: 58085,
    );

    expect(reason, contains('incomplete launch profile'));
  });

  test('a Client with no live Agent names its launcher', () {
    final reason = clientSelectionFailureReason(
      state(crossOwned: [client()]),
      agentPort: 58085,
    );

    expect(reason, contains('launcher-a'));
    expect(reason, contains('no live Agent'));
  });

  test('a manual Agent reports why it cannot own a Client', () {
    final reason = clientSelectionFailureReason(
      state(
        matchedAgent: agent(launcherId: null, runtimeNonce: null),
        ambiguous: [client()],
      ),
      agentPort: 58085,
    );

    expect(reason, contains('no managed launcher identity'));
  });

  test('no Agent and no Client names the port it expected', () {
    expect(
      clientSelectionFailureReason(state(), agentPort: 58085),
      'no Agent answers on port 58085',
    );
  });

  test('an ambiguous Agent set is reported before any Client detail', () {
    final reason = clientSelectionFailureReason(
      state(agentAmbiguous: true, crossOwned: [client()]),
      agentPort: 58085,
    );

    expect(reason, contains('more than one Agent'));
  });
}
