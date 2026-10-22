import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The forced-standalone ownership pre-check probes an explicitly targeted
/// endpoint with the same evidence as the attach path, so it must leave the
/// documented probe policy to discovery: an explicitly targeted endpoint keeps
/// the wider targeted bound, while speculative probes stay cheap. Narrowing it
/// to the speculative bound lets a healthy but busy daemon be mistaken for an
/// absent one, and the forced standalone run then falls through to the
/// standalone factory instead of refusing the owned Home.
void main() {
  test('forced standalone ownership pre-check keeps the discovery '
      'deadline policy', () async {
    final configUri = await Isolate.resolvePackageUri(
      Uri.parse('package:sanad_agent/core/config.dart'),
    );
    expect(configUri, isNotNull);

    final packageRoot = File.fromUri(configUri!).parent.parent.parent;
    final runner = File(
      '${packageRoot.path}/lib/cli/oneshot/oneshot_runner.dart',
    );
    expect(runner.existsSync(), isTrue);
    final source = runner.readAsStringSync();

    expect(
      source,
      isNot(contains('speculativeProbeTimeout')),
      reason:
          'The runner must not narrow an explicitly targeted endpoint to the '
          'speculative probe bound.',
    );
    expect(
      source,
      isNot(contains('targetedProbeTimeout')),
      reason:
          'The runner must not pin or widen a single bound; discovery selects '
          'the deadline by probe scope.',
    );
    expect(
      'LocalGatewayDiscovery('.allMatches(source).length,
      lessThanOrEqualTo(1),
      reason:
          'Mode resolution and the ownership pre-check must share one '
          'run-scoped discovery instead of ad-hoc instances.',
    );
  });
}
