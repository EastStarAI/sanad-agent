import 'package:sanad_agent/capabilities/runtime/workspace_tools/project_env_redactor.dart';
import 'package:test/test.dart';

void main() {
  test('.envrc is a project environment file', () {
    expect(ProjectEnvRedactor.isProjectEnvFile('/p/.envrc'), isTrue);
  });

  test('only exact template names stay readable', () {
    for (final name in ['.env.example', '.env.sample', '.env.template']) {
      expect(
        ProjectEnvRedactor.isProjectEnvFile('/p/$name'),
        isFalse,
        reason: name,
      );
    }
    for (final name in [
      '.env.example.local',
      '.env.local.example.bak',
      '.env.sample.prod',
      'example.secrets.env',
      '.env',
      '.env.local',
    ]) {
      expect(
        ProjectEnvRedactor.isProjectEnvFile('/p/$name'),
        isTrue,
        reason: name,
      );
    }
  });

  test('every line of a multi-line quoted value is redacted', () {
    const pem = 'first-body-secretline';
    const content =
        'PRIVATE_KEY="-----BEGIN ' 'PRIVATE KEY-----\n'
        '$pem\n'
        'second-body-QUJDREVG\n'
        '-----END ' 'PRIVATE KEY-----"\n'
        "SINGLE='a\n"
        "b=c'\n"
        'AFTER=visible-name\n';
    final redacted = ProjectEnvRedactor.redact(content);
    expect(redacted, isNot(contains('secretline')));
    expect(redacted, isNot(contains('QUJDREVG')));
    expect(redacted, isNot(contains('BEGIN PRIVATE KEY')));
    expect(redacted, isNot(contains('b=c')));
    expect(redacted, contains('PRIVATE_KEY=<redacted>'));
    expect(redacted, contains('AFTER=<redacted>'));
    expect(redacted.split('\n').length, content.split('\n').length);
  });

  test('envrc shell lines are redacted except export names and comments', () {
    final redacted = ProjectEnvRedactor.redact(
      '# direnv\nexport TOKEN=abc123\nsource_env .secrets\nPATH_add bin\n',
    );
    expect(redacted, contains('# direnv'));
    expect(redacted, contains('export TOKEN=<redacted>'));
    expect(redacted, isNot(contains('abc123')));
    expect(redacted, isNot(contains('.secrets')));
  });
}
