import 'dart:convert';
import 'dart:io';

import 'package:sanad_release_contract/release_contract.dart';
import 'package:test/test.dart';

void main() {
  test('the checked-in contract publishes every official Agent target', () {
    final contract =
        jsonDecode(
              File(
                '../release/release-contract.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    final targets = declaredAgentTargets(contract['artifacts'] as List);

    expect(targets, contains('linux/arm64'));
    validateRequiredAgentTargets(targets);
    for (final target in requiredAgentReleaseTargets) {
      expect(targets, contains(target.label), reason: target.label);
    }
  });

  test('a declared Agent target set that drops Linux arm64 fails', () {
    final contract =
        jsonDecode(
              File(
                '../release/release-contract.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final withoutArm64 = (contract['artifacts'] as List)
        .where(
          (raw) =>
              raw is! Map ||
              raw['component'] != 'agent' ||
              raw['platform'] != 'linux' ||
              raw['architecture'] != 'arm64',
        )
        .toList();

    expect(
      () => validateRequiredAgentTargets(declaredAgentTargets(withoutArm64)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('linux/arm64'), contains('official Agent targets')),
        ),
      ),
    );
  });

  test('only public Agent artifacts count as published targets', () {
    // A non-public or non-Agent entry never satisfies a required target, so a
    // contract cannot claim a target with an unpublished artifact.
    final artifacts = <Map<String, Object?>>[
      for (final target in requiredAgentReleaseTargets)
        {
          'component': 'agent',
          'platform': target.platform,
          'architecture': target.architecture,
          'public': !(target.platform == 'linux' && target.architecture == 'arm64'),
        },
      {
        'component': 'client',
        'platform': 'linux',
        'architecture': 'arm64',
        'public': true,
      },
    ];

    expect(
      declaredAgentTargets(artifacts),
      isNot(contains('linux/arm64')),
    );
    expect(
      () => validateRequiredAgentTargets(declaredAgentTargets(artifacts)),
      throwsFormatException,
    );
  });
}
