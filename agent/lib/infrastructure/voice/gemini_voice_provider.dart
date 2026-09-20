import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'realtime_voice_provider.dart';

/// Gemini Multimodal Live API implementation of [RealtimeVoiceProvider].
class GeminiRealtimeVoiceProvider extends RealtimeVoiceProvider {
  final _logger = Logger('GeminiRealtimeVoiceProvider');
  WebSocket? _webSocket;
  final _eventController = StreamController<RealtimeVoiceEvent>.broadcast();
  late String _sessionId;
  StreamSubscription? _socketSubscription;

  /// Connector callback override for testing purposes.
  Future<WebSocket> Function(String url)? websocketConnector;

  @override
  Stream<RealtimeVoiceEvent> get outputEvents => _eventController.stream;

  @override
  Future<void> connect(Map<String, dynamic> sessionConfig) async {
    _sessionId = sessionConfig['session_id'] as String? ?? 'voice_session';
    final config = getIt<Config>();
    final geminiKey = config.getEnvVar('GEMINI_API_KEY');
    final apiKey = geminiKey.isNotEmpty ? geminiKey : config.llmApiKey;

    if (apiKey.isEmpty) {
      throw StateError('LLM_API_KEY or GEMINI_API_KEY is not configured');
    }

    final host = 'generativelanguage.googleapis.com';
    final path =
        '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
    final url = 'wss://$host$path?key=$apiKey';

    _logger.info(
      'Connecting to Gemini Multimodal Live API at wss://$host (Key length: ${apiKey.length})...',
    );

    try {
      _webSocket = websocketConnector != null
          ? await websocketConnector!(url)
          : await WebSocket.connect(url);
      _logger.info('Connected to Gemini Multimodal Live API');

      // Start listening to the WebSocket
      _socketSubscription = _webSocket!.listen(
        (data) => _handleIncomingMessage(data),
        onDone: () {
          final closeCode = _webSocket?.closeCode;
          final closeReason = _webSocket?.closeReason;
          _logger.warning(
            'Gemini Live WebSocket closed by server. '
            'Code: $closeCode, Reason: "$closeReason"',
          );
          // Common close codes:
          // 1000 = Normal closure
          // 1008 = Policy Violation (bad model name, invalid config, quota exceeded)
          // 1011 = Internal Error
          close();
        },
        onError: (err) {
          _logger.severe('Gemini Live WebSocket error: $err');
          close();
        },
      );

      // Send the initial setup message
      await _sendSetupMessage(sessionConfig);
    } catch (e, stack) {
      _logger.severe('Failed to connect to Gemini Live API', e, stack);
      rethrow;
    }
  }

  Future<void> _sendSetupMessage(Map<String, dynamic> sessionConfig) async {
    final config = getIt<Config>();
    final envVoiceModel = config.getEnvVar('GEMINI_VOICE_MODEL');
    final model = envVoiceModel.isNotEmpty
        ? envVoiceModel
        : (sessionConfig['model'] as String? ??
              'models/gemini-2.0-flash-live-001');
    final voiceName =
        sessionConfig['voice_name'] as String? ??
        'Aoede'; // Puck, Charon, Kore, Fenrir, Aoede

    // Gather and format tools — strip 'required' as Gemini Live API rejects it
    final toolsRegistry = getIt<ToolsRegistry>();
    final functionDeclarations = toolsRegistry.allTools.map((tool) {
      final rawParams = tool.schema.parameters.isNotEmpty
          ? _convertSchemaToUppercaseTypes(tool.schema.parameters)
          : <String, dynamic>{
              'type': 'OBJECT',
              'properties': <String, dynamic>{},
            };

      // Remove 'required' — Gemini Live API does not support it in function declarations
      final params = Map<String, dynamic>.from(rawParams)..remove('required');

      return {
        'name': tool.schema.name,
        'description': tool.schema.description,
        'parameters': params,
      };
    }).toList();

    final setupPayload = {
      'setup': {
        'model': model,
        'systemInstruction': {
          'parts': [
            {
              'text':
                  'You are a helpful voice assistant. Respond concisely and naturally. You have access to local tools to help the user.',
            },
          ],
        },
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voiceName},
            },
          },
        },
        if (functionDeclarations.isNotEmpty)
          'tools': [
            {'functionDeclarations': functionDeclarations},
          ],
      },
    };

    _logger.info(
      'Sending setup message to Gemini Live API with ${functionDeclarations.length} tools',
    );
    _logger.info('Gemini Live setup payload sent');
    _webSocket?.add(jsonEncode(setupPayload));
  }

  /// Handles incoming messages from Gemini Live API.
  ///
  /// Gemini Live API v1beta sends responses as **binary WebSocket frames**,
  /// not text frames. We handle two cases:
  /// 1. Binary UTF-8 JSON → control messages (setupComplete, serverContent, toolCall)
  /// 2. Binary non-JSON → raw 16-bit PCM audio at 24kHz mono
  void _handleIncomingMessage(dynamic rawMessage) async {
    String? jsonStr;
    List<int>? binaryData;

    if (rawMessage is String) {
      jsonStr = rawMessage;
    } else if (rawMessage is List<int>) {
      binaryData = rawMessage;
      // Try to decode binary as UTF-8 JSON (Gemini sends control messages as binary text frames)
      try {
        final decoded = utf8.decode(rawMessage);
        if (decoded.trimLeft().startsWith('{')) {
          jsonStr = decoded;
        }
      } catch (_) {
        // Not valid UTF-8 — treat as raw PCM audio below
      }
    } else {
      _logger.warning(
        'Unknown message type from Gemini: ${rawMessage.runtimeType}',
      );
      return;
    }

    // --- Handle JSON control messages ---
    if (jsonStr != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(jsonStr);

        // Log all top-level keys received
        _logger.info('Gemini message keys: ${data.keys.toList()}');

        // setupComplete signals that Gemini accepted our setup message
        if (data.containsKey('setupComplete')) {
          _logger.info('✅ Gemini setup complete! Session is ready.');
        }

        // Handle serverContent
        if (data.containsKey('serverContent')) {
          final serverContent = data['serverContent'] as Map;

          if (serverContent.containsKey('interrupted') &&
              serverContent['interrupted'] == true) {
            _logger.info('Gemini: Interrupted by user/VAD');
            _eventController.add(InterruptedEvent());
          }

          // Parse user speech transcription
          if (serverContent.containsKey('userTurn')) {
            final userTurn = serverContent['userTurn'] as Map;
            if (userTurn.containsKey('parts')) {
              final parts = userTurn['parts'] as List;
              for (final part in parts) {
                if (part is Map && part.containsKey('text')) {
                  final text = part['text'] as String;
                  if (text.isNotEmpty) {
                    _eventController.add(UserTranscriptionEvent(text));
                  }
                }
              }
            }
          }

          // Parse model content (audio/text)
          if (serverContent.containsKey('modelTurn')) {
            final modelTurn = serverContent['modelTurn'] as Map;
            if (modelTurn.containsKey('parts')) {
              final parts = modelTurn['parts'] as List;
              for (final part in parts) {
                if (part is! Map) continue;

                // Text response/transcription
                if (part.containsKey('text')) {
                  final text = part['text'] as String;
                  if (text.isNotEmpty) {
                    _eventController.add(TextResponseEvent(text));
                  }
                }

                // Audio response (base64 encoded)
                if (part.containsKey('inlineData')) {
                  final inlineData = part['inlineData'] as Map;
                  final base64Data = inlineData['data'] as String?;
                  if (base64Data != null && base64Data.isNotEmpty) {
                    final pcmChunk = base64Decode(base64Data);
                    _logger.info(
                      '🔊 Base64 audio from Gemini JSON: ${pcmChunk.length} bytes',
                    );
                    _eventController.add(AudioOutputEvent(pcmChunk));
                  }
                }
              }
            }
          }
        }

        // Handle tool calls
        if (data.containsKey('toolCall')) {
          final toolCall = data['toolCall'] as Map;
          if (toolCall.containsKey('functionCalls')) {
            final functionCalls = toolCall['functionCalls'] as List;
            for (final call in functionCalls) {
              if (call is Map) {
                final id = call['id'] as String?;
                final name = call['name'] as String?;
                final args = Map<String, dynamic>.from(
                  call['args'] as Map? ?? {},
                );
                if (id != null && name != null) {
                  _executeToolCallLocally(id, name, args);
                }
              }
            }
          }
        }
      } catch (e, stack) {
        _logger.severe(
          'Error processing JSON message from Gemini Live API',
          e,
          stack,
        );
      }
      return; // JSON handled
    }

    // --- Handle raw binary PCM audio ---
    // Gemini Live API native audio models send raw 16-bit PCM binary frames (24kHz, mono, little-endian)
    if (binaryData != null && binaryData.isNotEmpty) {
      _logger.info(
        '🔊 Raw PCM audio from Gemini: ${binaryData.length} bytes '
        '(~${(binaryData.length / 2 / 24000 * 1000).toStringAsFixed(0)}ms)',
      );
      _eventController.add(AudioOutputEvent(binaryData));
    }
  }

  Future<void> _executeToolCallLocally(
    String id,
    String name,
    Map<String, dynamic> args,
  ) async {
    _logger.info(
      'Gemini Live requested tool call: $name (id: $id) with args: $args',
    );

    String output;
    try {
      final toolsRegistry = getIt<ToolsRegistry>();
      final tool = toolsRegistry.getTool(name);

      if (tool == null) {
        output = 'Error: Tool $name not found in local daemon tools registry';
        _logger.warning(output);
      } else {
        final context = ToolContext(sessionId: _sessionId, toolCallId: id);
        output = await tool.execute(args, context: context);
        _logger.info(
          'Tool $name executed successfully. Output size: ${output.length} chars',
        );
      }
    } catch (e, stack) {
      output = 'Error executing tool: $e';
      _logger.severe('Exception executing tool $name', e, stack);
    }

    final responsePayload = {
      'toolResponse': {
        'functionResponses': [
          {
            'id': id,
            'response': {'output': output},
          },
        ],
      },
    };

    _webSocket?.add(jsonEncode(responsePayload));
  }

  @override
  void handleInputAudio(List<int> pcmChunk16kHz) {
    if (_webSocket == null || _webSocket!.readyState != WebSocket.open) {
      _logger.warning(
        'handleInputAudio: WebSocket not open (state: ${_webSocket?.readyState}). Dropping chunk.',
      );
      return;
    }

    final base64Audio = base64Encode(pcmChunk16kHz);
    final audioPayload = {
      'realtimeInput': {
        'mediaChunks': [
          {'mimeType': 'audio/pcm;rate=16000', 'data': base64Audio},
        ],
      },
    };

    _webSocket?.add(jsonEncode(audioPayload));
  }

  @override
  void handleControlEvent(String eventName, Map<String, dynamic> payload) {
    _logger.info('Received Gemini Live control event');
  }

  @override
  Future<void> close() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _webSocket?.close();
    _webSocket = null;
  }

  Map<String, dynamic> _convertSchemaToUppercaseTypes(
    Map<String, dynamic> schema,
  ) {
    final result = Map<String, dynamic>.from(schema);
    if (result.containsKey('type') && result['type'] is String) {
      result['type'] = (result['type'] as String).toUpperCase();
    }
    if (result.containsKey('properties') && result['properties'] is Map) {
      final properties = Map<String, dynamic>.from(result['properties'] as Map);
      for (final key in properties.keys) {
        if (properties[key] is Map) {
          properties[key] = _convertSchemaToUppercaseTypes(
            Map<String, dynamic>.from(properties[key] as Map),
          );
        }
      }
      result['properties'] = properties;
    }
    if (result.containsKey('items') && result['items'] is Map) {
      result['items'] = _convertSchemaToUppercaseTypes(
        Map<String, dynamic>.from(result['items'] as Map),
      );
    }
    return result;
  }
}
