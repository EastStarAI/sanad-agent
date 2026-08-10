import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Linux release workflow enforces its compatibility gates', () async {
    final workflow = File('../.github/workflows/release.yml');
    expect(workflow.existsSync(), isTrue, reason: 'release workflow must exist');

    final text = await workflow.readAsString();
    final start = text.indexOf('\n  client-linux-web:');
    final end = start < 0 ? -1 : text.indexOf('\n  client-android:', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final linuxJob = text.substring(start, end);
    expect(linuxJob, contains('runs-on: ubuntu-22.04'));
    expect(linuxJob, isNot(contains('runs-on: ubuntu-24.04')));
    expect(linuxJob, contains('libasound2-dev xvfb'));
    expect(
      linuxJob,
      contains('scripts/release/test_linux_release_bundle.sh'),
    );
    expect(linuxJob, contains('release/linux/build_linux_deb.sh'));
    expect(linuxJob, contains('scripts/release/test_linux_deb_package.sh'));
    expect(linuxJob, contains('--install'));
    expect(
      linuxJob,
      contains('fvm flutter build linux --release'),
      reason: 'the compatibility gates must guard the actual Linux build job',
    );
  });

  test('release contract publishes DEB as the primary Linux package', () async {
    final contract =
        jsonDecode(
              await File('../release/release-contract.json').readAsString(),
            )
            as Map<String, dynamic>;
    final artifacts = (contract['artifacts'] as List).cast<Map<String, dynamic>>();
    final linuxFormats = artifacts
        .where(
          (artifact) =>
              artifact['component'] == 'client' &&
              artifact['platform'] == 'linux' &&
              artifact['architecture'] == 'x64' &&
              artifact['public'] == true,
        )
        .map((artifact) => artifact['format'])
        .toSet();

    expect(linuxFormats, containsAll(<String>{'deb', 'tar.gz'}));
    final redirects = await File(
      '../scripts/release/generate_client_download_redirects.sh',
    ).readAsString();
    expect(redirects, contains('linux\tx64\tdeb'));
  });
}
