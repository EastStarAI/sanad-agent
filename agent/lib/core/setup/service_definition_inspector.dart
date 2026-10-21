import 'dart:io';

import '../constants.dart';
import 'service_manager.dart';

/// The fields of a background service definition that decide which Agent
/// runs, how, and for which Home and service instance.
class ServiceDefinition {
  const ServiceDefinition({
    required this.executable,
    required this.arguments,
    required this.sanadHome,
    required this.serviceInstance,
  });

  final String executable;
  final List<String> arguments;
  final String sanadHome;

  /// Empty for the default service.
  final String serviceInstance;

  ServiceDefinition copyWith({
    String? executable,
    List<String>? arguments,
    String? sanadHome,
    String? serviceInstance,
  }) => ServiceDefinition(
    executable: executable ?? this.executable,
    arguments: arguments ?? this.arguments,
    sanadHome: sanadHome ?? this.sanadHome,
    serviceInstance: serviceInstance ?? this.serviceInstance,
  );

  Map<String, Object> toJson() => {
    'executable': executable,
    'arguments': arguments,
    'sanad_home': sanadHome,
    'service_instance': serviceInstance,
  };

  @override
  bool operator ==(Object other) =>
      other is ServiceDefinition &&
      other.executable == executable &&
      other.sanadHome == sanadHome &&
      other.serviceInstance == serviceInstance &&
      other.arguments.length == arguments.length &&
      Iterable<int>.generate(
        arguments.length,
      ).every((index) => other.arguments[index] == arguments[index]);

  @override
  int get hashCode => Object.hash(
    executable,
    Object.hashAll(arguments),
    sanadHome,
    serviceInstance,
  );

  @override
  String toString() => 'ServiceDefinition(${toJson()})';
}

/// Read-only comparison of the installed user service definition with the
/// one this Agent would generate. It never writes, registers, or starts.
///
/// Only the launchd plist and the systemd user unit are inspected; Windows
/// Clients refresh the Scheduled Task on every registration.
abstract final class ServiceDefinitionInspector {
  /// The definition this Agent's `service install` would write.
  static ServiceDefinition expected() {
    final invocation = ServiceManager.daemonInvocation();
    return ServiceDefinition(
      executable: invocation.executable,
      arguments: invocation.arguments,
      sanadHome: getSanadHome(),
      serviceInstance: ServiceManager.serviceInstance,
    );
  }

  /// The JSON report printed by `sanad service definition`.
  static Map<String, Object?> report() {
    final path = ServiceManager.getServiceConfigPath();
    final expected = ServiceDefinitionInspector.expected();
    ServiceDefinition? installed;
    final file = path.isEmpty ? null : File(path);
    if (file != null && file.existsSync()) {
      final content = file.readAsStringSync();
      installed = Platform.isMacOS
          ? parseLaunchdPlist(content)
          : parseSystemdUnit(
              content,
              serviceInstance: expected.serviceInstance,
            );
    }
    return {
      'platform': Platform.operatingSystem,
      'supported': path.isNotEmpty,
      ...compare(expected: expected, installed: installed),
    };
  }

  static Map<String, Object?> compare({
    required ServiceDefinition expected,
    required ServiceDefinition? installed,
  }) => {
    'installed': installed != null,
    'matches': installed != null && installed == expected,
    'expected': expected.toJson(),
    'installed_definition': installed?.toJson(),
  };

  static ServiceDefinition? parseLaunchdPlist(String content) {
    final program = RegExp(
      r'<key>ProgramArguments</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(content);
    if (program == null) return null;
    final values = RegExp(
      r'<string>(.*?)</string>',
      dotAll: true,
    ).allMatches(program.group(1)!).map((m) => _unxml(m.group(1)!)).toList();
    if (values.isEmpty) return null;
    final environment = RegExp(
      r'<key>EnvironmentVariables</key>\s*<dict>(.*?)</dict>',
      dotAll: true,
    ).firstMatch(content)?.group(1);
    String? env(String key) {
      if (environment == null) return null;
      final match = RegExp(
        '<key>${RegExp.escape(key)}</key>\\s*<string>(.*?)</string>',
        dotAll: true,
      ).firstMatch(environment);
      return match == null ? null : _unxml(match.group(1)!);
    }

    final home = env('SANAD_HOME');
    if (home == null) return null;
    return ServiceDefinition(
      executable: values.first,
      arguments: values.sublist(1),
      sanadHome: home,
      serviceInstance: env('SANAD_SERVICE_INSTANCE') ?? '',
    );
  }

  /// systemd units carry the instance only in their file name, so the caller
  /// supplies the instance it located the unit by.
  static ServiceDefinition? parseSystemdUnit(
    String content, {
    required String serviceInstance,
  }) {
    final exec = RegExp(
      r'^ExecStart=(.*)$',
      multiLine: true,
    ).firstMatch(content);
    final home = RegExp(
      r'^Environment="SANAD_HOME=(.*)"\s*$',
      multiLine: true,
    ).firstMatch(content);
    if (exec == null || home == null) return null;
    final tokens = _systemdTokens(exec.group(1)!);
    if (tokens.isEmpty) return null;
    return ServiceDefinition(
      executable: tokens.first,
      arguments: tokens.sublist(1),
      sanadHome: _systemdUnescape(home.group(1)!),
      serviceInstance: serviceInstance,
    );
  }

  static List<String> _systemdTokens(String command) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    var inToken = false;
    for (var index = 0; index < command.length; index++) {
      final char = command[index];
      if (char == r'\' && quoted && index + 1 < command.length) {
        buffer.write(command[++index]);
      } else if (char == '"') {
        quoted = !quoted;
        inToken = true;
      } else if (char == ' ' && !quoted) {
        if (inToken) tokens.add(buffer.toString().replaceAll('%%', '%'));
        buffer.clear();
        inToken = false;
      } else {
        buffer.write(char);
        inToken = true;
      }
    }
    if (inToken) tokens.add(buffer.toString().replaceAll('%%', '%'));
    return tokens;
  }

  static String _systemdUnescape(String value) => value
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\')
      .replaceAll('%%', '%');

  static String _unxml(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
