import 'dart:convert';

import 'package:http/http.dart' as http;

import 'copilot_token_exchange_result.dart';
import 'provider_protocol_constants.dart';

/// Typed Copilot token-exchange failure.
///
/// [permanent] is true for account rejection (HTTP 401/403/404) so the
/// lifecycle can persist `relogin_required`. Transient HTTP failures stay
/// non-permanent and never loop into a re-login state.
class CopilotExchangeException implements Exception {
  final String message;
  final bool permanent;

  const CopilotExchangeException(this.message, {this.permanent = false});

  @override
  String toString() => 'CopilotExchangeException: $message';
}

/// Exchanges a GitHub user token for a short-lived Copilot API token.
///
/// Uses Dart `http.Client` only. Never shells out to `gh`, Copilot CLI, or
/// an SDK. The returned [CopilotTokenExchangeResult] never logs the token.
class CopilotTokenExchanger {
  /// GET `https://api.github.com/copilot_internal/v2/token`.
  ///
  /// [githubUserToken] is the long-lived GitHub user token from device-code
  /// approval. Classic `ghp_*` tokens are rejected before any network call.
  Future<CopilotTokenExchangeResult> exchange({
    required http.Client client,
    required String githubUserToken,
    DateTime? now,
    String? trustedEnterpriseDomain,
  }) async {
    final token = githubUserToken.trim();
    if (token.isEmpty) {
      throw const FormatException('GitHub user token is empty.');
    }
    if (GithubCopilotProtocol.isClassicPersonalAccessToken(token)) {
      throw FormatException(GithubCopilotProtocol.classicPatRejectionMessage);
    }

    final resp = await client.get(
      Uri.parse(GithubCopilotProtocol.tokenExchangeUrl),
      headers: {
        'Authorization': 'token $token',
        'Accept': GithubCopilotProtocol.githubAccept,
        'User-Agent': GithubCopilotProtocol.exchangeUserAgent,
        GithubCopilotProtocol.editorVersionHeader:
            GithubCopilotProtocol.editorVersion,
        GithubCopilotProtocol.integrationIdHeader:
            GithubCopilotProtocol.integrationId,
      },
    );

    if (resp.statusCode == 401 ||
        resp.statusCode == 403 ||
        resp.statusCode == 404) {
      throw const CopilotExchangeException(
        'GitHub Copilot is not available for this account.',
        permanent: true,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CopilotExchangeException(
        'Copilot token exchange failed: HTTP ${resp.statusCode}.',
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Copilot token exchange returned an unexpected payload.',
      );
    }
    return CopilotTokenExchangeResult.fromExchangeResponse(
      decoded,
      now: now,
      trustedEnterpriseDomain: trustedEnterpriseDomain,
    );
  }
}
