import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/core/utils/terminal_prompts.dart';
import 'package:sanad_agent/core/utils/credential_sanitizer.dart';

/// Warn and strip non-ASCII characters from credential values.
/// This prevents http encoding crashes when keys are copy-pasted with hidden spaces/lookalikes.
String checkNonAsciiCredential(String key, String value) {
  final sanitized = sanitizeCredential(value);
  if (sanitized == value) {
    return value;
  }

  final badChars = <String>[];
  for (int i = 0; i < value.length; i++) {
    final codeUnit = value.codeUnitAt(i);
    if (codeUnit > 127) {
      final ch = value[i];
      final hex = codeUnit.toRadixString(16).toUpperCase().padLeft(4, '0');
      badChars.add('  position $i: \'$ch\' (U+$hex)');
    }
  }

  final displayedBadChars = badChars.take(5).join('\n');
  final moreSuffix = badChars.length > 5 ? '\n  ... and more' : '';

  stderr.writeln(
    '\n  Warning: $key contains non-ASCII characters that will break API requests.\n'
    '  This usually happens when copy-pasting from a PDF, rich-text editor,\n'
    '  or web page that substitutes lookalike Unicode glyphs for ASCII letters.\n'
    '\n'
    '$displayedBadChars$moreSuffix\n'
    '\n  The non-ASCII characters have been stripped automatically.\n'
    '  If authentication fails, re-copy the key from the provider\'s dashboard.\n',
  );

  return sanitized;
}

Future<void> _waitForDeviceCodePoll(Duration duration) =>
    Future<void>.delayed(duration);

/// ChatGPT device-code login flow.
Future<String?> runCodexDeviceCodeFlow({
  http.Client? clientOverride,
  Future<void> Function(Duration duration) waitForPoll = _waitForDeviceCodePoll,
}) async {
  final issuer = 'https://auth.openai.com';
  final clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  final tokenUrl = 'https://auth.openai.com/oauth/token';

  print('\n[Device Authentication] Requesting device authorization code...');

  try {
    final client = clientOverride ?? http.Client();
    final usercodeUrl = Uri.parse('$issuer/api/accounts/deviceauth/usercode');
    final resp = await client.post(
      usercodeUrl,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'client_id': clientId}),
    );

    if (resp.statusCode != 200) {
      print('❌ Failed to request device auth: HTTP ${resp.statusCode}');
      print('Response: ${resp.body}');
      return null;
    }

    final deviceData = jsonDecode(resp.body) as Map<String, dynamic>;
    final userCode = deviceData['user_code']?.toString();
    final deviceAuthId = deviceData['device_auth_id']?.toString();

    final intervalRaw = deviceData['interval'];
    int pollInterval = 5;
    if (intervalRaw != null) {
      if (intervalRaw is int) {
        pollInterval = intervalRaw;
      } else if (intervalRaw is num) {
        pollInterval = intervalRaw.toInt();
      } else if (intervalRaw is String) {
        pollInterval = int.tryParse(intervalRaw) ?? 5;
      }
    }
    if (pollInterval < 3) {
      pollInterval = 3;
    }

    if (userCode == null || deviceAuthId == null) {
      print('❌ Device auth response was incomplete.');
      return null;
    }

    print('\nTo continue, please follow these steps:');
    print('\n  1. Open this URL in your browser:');
    print('     \x1B[94m$issuer/codex/device\x1B[0m');
    print('\n  2. Enter this 8-character code:');
    print('     \x1B[94m$userCode\x1B[0m');
    print('\nWaiting for you to complete sign-in in your browser...');
    print('(Press Ctrl+C to cancel anytime)\n');

    final tokenPollUrl = Uri.parse('$issuer/api/accounts/deviceauth/token');
    final maxWait = Duration(minutes: 15);
    final startTime = DateTime.now();
    String? authorizationCode;
    String? codeVerifier;

    while (DateTime.now().difference(startTime) < maxWait) {
      await waitForPoll(Duration(seconds: pollInterval));
      stdout.write('.');

      final pollResp = await client.post(
        tokenPollUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_auth_id': deviceAuthId,
          'user_code': userCode,
        }),
      );

      if (pollResp.statusCode == 200) {
        final codeResp = jsonDecode(pollResp.body) as Map<String, dynamic>;
        authorizationCode = codeResp['authorization_code']?.toString();
        codeVerifier = codeResp['code_verifier']?.toString();
        break;
      } else if (pollResp.statusCode == 403 || pollResp.statusCode == 404) {
        // User hasn't finished authenticating yet
        continue;
      } else {
        print('\n❌ Polling device auth failed: HTTP ${pollResp.statusCode}');
        return null;
      }
    }

    if (authorizationCode == null || codeVerifier == null) {
      print('\n❌ Authentication timed out.');
      return null;
    }

    print('\n\n[Device Authentication] Exchanging code for API credentials...');
    final redirectUri = '$issuer/deviceauth/callback';

    final tokenResp = await client.post(
      Uri.parse(tokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'code': authorizationCode,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': codeVerifier,
      },
    );

    if (tokenResp.statusCode != 200) {
      print('❌ Token exchange failed: HTTP ${tokenResp.statusCode}');
      print('Response: ${tokenResp.body}');
      return null;
    }

    final tokens = jsonDecode(tokenResp.body) as Map<String, dynamic>;
    final accessToken = tokens['access_token']?.toString();

    if (accessToken == null || accessToken.isEmpty) {
      print('❌ Token exchange did not return an access_token.');
      return null;
    }

    print('\n🔑 Device authentication successful!');
    return accessToken;
  } catch (e) {
    print('❌ An error occurred during device authentication: $e');
    return null;
  }
}

/// Dynamic Model Fetcher from API.
Future<List<String>> fetchModelsFromApi({
  required String provider,
  required String llmBaseUrl,
  required String llmApiKey,
  http.Client? clientOverride,
}) async {
  final client = clientOverride ?? http.Client();
  try {
    if (provider == 'ollama') {
      final response = await client
          .get(Uri.parse('$llmBaseUrl/api/tags'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final modelsList = decoded['models'] as List?;
        if (modelsList != null) {
          return modelsList.map((m) => (m as Map)['name'] as String).toList();
        }
      }
    } else {
      // OpenAI compatibility models list
      final response = await client
          .get(
            Uri.parse('$llmBaseUrl/models'),
            headers: {
              if (llmApiKey.isNotEmpty) 'Authorization': 'Bearer $llmApiKey',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final data = decoded['data'] as List?;
        if (data != null) {
          final fetched = data.map((m) => (m as Map)['id'] as String).toList();
          fetched.sort();
          return fetched;
        }
      }
    }
  } catch (e) {
    // Silent fallback
  } finally {
    if (clientOverride == null) {
      client.close();
    }
  }
  return const [];
}

/// Ask the user to interactively choose a model from the list of fallbackModels or dynamically fetched models.
Future<String> promptModelSelection(
  ProviderProfile profile,
  String defaultModel, {
  String? llmBaseUrl,
  String? llmApiKey,
  http.Client? clientOverride,
}) async {
  var models = profile.fallbackModels;

  // 1. If Ollama, automatically fetch the local tags silently in the background
  if (profile.name == 'ollama' && llmBaseUrl != null) {
    stdout.write('\n🔍 Fetching active local models from Ollama...');
    final localModels = await fetchModelsFromApi(
      provider: 'ollama',
      llmBaseUrl: llmBaseUrl,
      llmApiKey: '',
      clientOverride: clientOverride,
    );
    if (localModels.isNotEmpty) {
      models = localModels;
      stdout.write(' done (found ${models.length} models).\n');
    } else {
      stdout.write(' failed (using fallback presets).\n');
    }
  }

  if (models.isEmpty) {
    stdout.write('Enter model name (default: $defaultModel): ');
    final input = stdin.readLineSync()?.trim();
    return (input != null && input.isNotEmpty) ? input : defaultModel;
  }

  // 2. Build selection options list
  final options = [
    ...models.map((m) => '$m${m == defaultModel ? " (Recommended)" : ""}'),
    if (profile.name != 'ollama' && profile.name != 'xai-oauth')
      '🔍 Fetch all available models from API',
    'Custom model name (type manually)',
  ];

  final selectedIdx = selectInteractive(
    '\nSelect model for ${profile.displayName}:',
    options,
  );

  // Check which option was selected
  if (selectedIdx < models.length) {
    return models[selectedIdx];
  }

  final isFetchOption =
      profile.name != 'ollama' &&
      profile.name != 'xai-oauth' &&
      selectedIdx == models.length;

  if (isFetchOption) {
    if (llmBaseUrl == null || llmApiKey == null || llmApiKey.isEmpty) {
      print(
        '\n⚠️ Cannot fetch without API credentials. Please type the model name manually.',
      );
      stdout.write('Enter custom model name: ');
      final custom = stdin.readLineSync()?.trim();
      return (custom != null && custom.isNotEmpty) ? custom : defaultModel;
    }

    stdout.write('\n🔍 Fetching models from ${profile.displayName} API...');
    final liveModels = await fetchModelsFromApi(
      provider: profile.name,
      llmBaseUrl: llmBaseUrl,
      llmApiKey: llmApiKey,
      clientOverride: clientOverride,
    );

    if (liveModels.isNotEmpty) {
      print(' done (found ${liveModels.length} models).');
      final newOptions = [
        ...liveModels.map(
          (m) => '$m${m == defaultModel ? " (Recommended)" : ""}',
        ),
        'Custom model name (type manually)',
      ];
      final newIdx = selectInteractive(
        '\nSelect from all fetched models:',
        newOptions,
      );
      if (newIdx < liveModels.length) {
        return liveModels[newIdx];
      }
    } else {
      print(' failed or returned empty list.');
    }

    stdout.write('Enter custom model name: ');
    final custom = stdin.readLineSync()?.trim();
    return (custom != null && custom.isNotEmpty) ? custom : defaultModel;
  } else {
    // Custom option
    stdout.write('Enter custom model name: ');
    final custom = stdin.readLineSync()?.trim();
    return (custom != null && custom.isNotEmpty) ? custom : defaultModel;
  }
}

/// Dynamic Connection Tester for all providers.
Future<bool> testProviderConnection({
  required String provider,
  required String llmBaseUrl,
  required String llmModel,
  required String llmApiKey,
  http.Client? clientOverride,
}) async {
  final client = clientOverride ?? http.Client();
  try {
    print('\n[Connection Test] Testing connection to $provider ($llmModel)...');

    // 1. Prepare candidate metadata endpoints to try first (fast, no model load)
    final metadataUrls = <Uri>[];
    final Map<String, String> getHeaders = {};

    if (provider == 'anthropic') {
      getHeaders['x-api-key'] = llmApiKey;
      getHeaders['anthropic-version'] = '2023-06-01';
      metadataUrls.add(Uri.parse('$llmBaseUrl/v1/models'));
    } else if (provider == 'openai-codex') {
      getHeaders['Authorization'] = 'Bearer $llmApiKey';
      metadataUrls.add(Uri.parse('$llmBaseUrl/models?client_version=1.0.0'));
    } else if (provider == 'xai-oauth') {
      getHeaders['Authorization'] = 'Bearer $llmApiKey';
      metadataUrls.add(Uri.parse('$llmBaseUrl/models'));
    } else if (provider == 'ollama') {
      metadataUrls.add(Uri.parse('$llmBaseUrl/api/tags'));
      metadataUrls.add(Uri.parse('$llmBaseUrl/v1/models'));
      metadataUrls.add(Uri.parse('$llmBaseUrl/api/version'));
    } else if (provider == 'lm-studio' || provider == 'lmstudio') {
      metadataUrls.add(Uri.parse('$llmBaseUrl/v1/models'));
      metadataUrls.add(Uri.parse('$llmBaseUrl/api/v1/models'));
      metadataUrls.add(Uri.parse('$llmBaseUrl/models'));
    } else if (provider == 'llama-cpp' || provider == 'llamacpp') {
      metadataUrls.add(Uri.parse('$llmBaseUrl/v1/models'));
      metadataUrls.add(Uri.parse('$llmBaseUrl/models'));
    } else {
      if (llmApiKey.isNotEmpty) {
        getHeaders['Authorization'] = 'Bearer $llmApiKey';
      }
      metadataUrls.add(Uri.parse('$llmBaseUrl/models'));
      if (!llmBaseUrl.endsWith('/v1') && !llmBaseUrl.endsWith('/v1/')) {
        metadataUrls.add(
          Uri.parse('${llmBaseUrl.replaceAll(RegExp(r'/$'), '')}/v1/models'),
        );
      }
    }

    // 2. Try the fast metadata GET endpoints first
    bool metadataSuccess = false;
    for (final url in metadataUrls) {
      try {
        final response = await client
            .get(url, headers: getHeaders)
            .timeout(const Duration(seconds: 4));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          print(
            '\x1B[92m✓ Connection successful! Validated $provider server is running via metadata endpoint: $url\x1B[0m',
          );
          metadataSuccess = true;
          break;
        } else if (response.statusCode == 401 || response.statusCode == 403) {
          print(
            '\x1B[91m❌ Connection test failed: Unauthorized (invalid API key) via: $url\x1B[0m',
          );
          return false;
        }
      } catch (_) {
        // Continue to next metadata URL or fallback
      }
    }

    if (metadataSuccess) {
      return true;
    }

    // 3. Fallback to POST chat/completion or messages endpoint if metadata probe failed or was not supported
    final Uri fallbackUrl;
    final Map<String, String> postHeaders = {
      'Content-Type': 'application/json',
    };
    final Map<String, dynamic> body;

    if (provider == 'anthropic') {
      fallbackUrl = Uri.parse('$llmBaseUrl/v1/messages');
      postHeaders['x-api-key'] = llmApiKey;
      postHeaders['anthropic-version'] = '2023-06-01';
      body = {
        'model': llmModel,
        'max_tokens': 1,
        'messages': [
          {'role': 'user', 'content': 'ping'},
        ],
      };
    } else if (provider == 'openai-codex') {
      // openai-codex does not have a standard chat completions endpoint at this path.
      // We rely heavily on the metadata probe above to validate the connection.
      // If we reach here, we'll try a generic fallback without the /v1/chat/completions suffix.
      fallbackUrl = Uri.parse('$llmBaseUrl/chat/completions');
      postHeaders['Authorization'] = 'Bearer $llmApiKey';
      body = {
        'model': llmModel,
        'messages': [
          {'role': 'user', 'content': 'ping'},
        ],
        'max_tokens': 1,
      };
    } else if (provider == 'xai-oauth') {
      fallbackUrl = Uri.parse('$llmBaseUrl/v1/chat/completions');
      postHeaders['Authorization'] = 'Bearer $llmApiKey';
      body = {
        'model': llmModel,
        'messages': [
          {'role': 'user', 'content': 'ping'},
        ],
        'max_tokens': 1,
      };
    } else {
      fallbackUrl = Uri.parse('$llmBaseUrl/chat/completions');
      if (llmApiKey.isNotEmpty) {
        postHeaders['Authorization'] = 'Bearer $llmApiKey';
      }
      body = {
        'model': llmModel,
        'messages': [
          {'role': 'user', 'content': 'ping'},
        ],
        'max_tokens': 1,
      };
    }

    final response = await client
        .post(fallbackUrl, headers: postHeaders, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      print(
        '\x1B[92m✓ Connection successful! Validated $provider with model $llmModel.\x1B[0m',
      );
      return true;
    } else {
      print(
        '\x1B[91m❌ Connection test failed with status code ${response.statusCode}.\x1B[0m',
      );
      print('Response: ${response.body}');
      return false;
    }
  } catch (e) {
    print('\x1B[91m❌ Connection test failed: $e\x1B[0m');
    return false;
  } finally {
    if (clientOverride == null) {
      client.close();
    }
  }
}
