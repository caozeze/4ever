import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/ai/llm_generation_config.dart';
import '../../domain/ai/llm_model_config.dart';
import '../../domain/ai/llm_response.dart';
import '../../domain/ai/llm_runtime.dart';
import '../../domain/ai/llm_runtime_status.dart';
import '../../domain/ai/llm_token_event.dart';

class DebugHttpLlmRuntime implements LlmRuntime {
  DebugHttpLlmRuntime({required Uri endpoint}) : _endpoint = endpoint;

  final Uri _endpoint;
  String _state = 'unloaded';
  String? _loadedModelId;
  String? _lastError;

  @override
  Future<void> initialize(LlmModelConfig config) async {
    _loadedModelId = config.modelId;
    _lastError = null;
    _state = 'ready';
  }

  @override
  Stream<LlmTokenEvent> generateStream({
    required String prompt,
    List<Object> attachments = const <Object>[],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  }) async* {
    final response = await generateOnce(prompt: prompt, config: config);
    yield LlmTokenEvent(
      requestId: DateTime.now().microsecondsSinceEpoch.toString(),
      type: 'done',
      text: response.text,
    );
  }

  @override
  Future<LlmResponse> generateOnce({
    required String prompt,
    List<Object> attachments = const <Object>[],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .postUrl(_endpoint)
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(
        jsonEncode(<String, Object?>{
          'prompt': prompt,
          'max_tokens': config.maxTokens,
          'model_id': _loadedModelId ?? 'gemma-4-e2b-it-coreml-ios',
        }),
      );
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(
        const Duration(minutes: 10),
      );
      final responseBody = await utf8
          .decodeStream(response)
          .timeout(const Duration(minutes: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _state = 'failed';
        _lastError = responseBody;
        throw StateError('Debug Gemma runtime failed: $responseBody');
      }
      final data = jsonDecode(responseBody) as Map<String, Object?>;
      final text = data['text'] as String? ?? '';
      return LlmResponse(
        text: text,
        modelId:
            data['model_id'] as String? ?? _loadedModelId ?? 'debug-gemma4',
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<LlmRuntimeStatus> getStatus() async {
    return LlmRuntimeStatus(
      state: _state,
      errorCode: _lastError == null ? null : 'DEBUG_HTTP_RUNTIME_FAILED',
      errorMessage: _lastError,
      loadedModelId: _loadedModelId,
    );
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> unload() async {
    _state = 'unloaded';
    _loadedModelId = null;
    _lastError = null;
  }
}
