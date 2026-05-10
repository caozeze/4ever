import 'dart:convert';

import 'package:dartantic_ai/dartantic_ai.dart';

import '../../domain/ai/llm_generation_config.dart';
import '../../domain/ai/llm_runtime.dart';
import '../observability/agent_trace_sink.dart';

final class LocalGemmaProvider
    extends
        Provider<
          ChatModelOptions,
          EmbeddingsModelOptions,
          MediaGenerationModelOptions
        > {
  const LocalGemmaProvider({
    required LlmRuntime runtime,
    required LlmGenerationConfig generationConfig,
    AgentTraceSink traceSink = const NoopAgentTraceSink(),
  }) : _runtime = runtime,
       _generationConfig = generationConfig,
       _traceSink = traceSink,
       super(
         name: 'local_gemma',
         displayName: 'Local Gemma',
         defaultModelNames: const <ModelKind, String>{
           ModelKind.chat: 'local-gemma',
         },
       );

  final LlmRuntime _runtime;
  final LlmGenerationConfig _generationConfig;
  final AgentTraceSink _traceSink;

  @override
  ChatModel<ChatModelOptions> createChatModel({
    String? name,
    List<Tool>? tools,
    double? temperature,
    bool enableThinking = false,
    ChatModelOptions? options,
  }) {
    return LocalGemmaChatModel(
      runtime: _runtime,
      generationConfig: _generationConfig,
      name: name ?? defaultModelNames[ModelKind.chat] ?? 'local-gemma',
      tools: tools,
      temperature: temperature,
      traceSink: _traceSink,
    );
  }

  @override
  EmbeddingsModel<EmbeddingsModelOptions> createEmbeddingsModel({
    String? name,
    EmbeddingsModelOptions? options,
  }) {
    throw UnsupportedError('Local Gemma embeddings are not implemented.');
  }

  @override
  MediaGenerationModel<MediaGenerationModelOptions> createMediaModel({
    String? name,
    List<Tool>? tools,
    MediaGenerationModelOptions? options,
  }) {
    throw UnsupportedError('Local Gemma media generation is not implemented.');
  }

  @override
  Stream<ModelInfo> listModels() {
    return Stream<ModelInfo>.value(
      ModelInfo(
        name: defaultModelNames[ModelKind.chat] ?? 'local-gemma',
        providerName: name,
        kinds: const <ModelKind>{ModelKind.chat},
      ),
    );
  }
}

final class LocalGemmaChatModel extends ChatModel<ChatModelOptions> {
  LocalGemmaChatModel({
    required LlmRuntime runtime,
    required LlmGenerationConfig generationConfig,
    required super.name,
    AgentTraceSink traceSink = const NoopAgentTraceSink(),
    super.tools,
    super.temperature,
  }) : _runtime = runtime,
       _generationConfig = generationConfig,
       _traceSink = traceSink,
       super(defaultOptions: const ChatModelOptions());

  final LlmRuntime _runtime;
  final LlmGenerationConfig _generationConfig;
  final AgentTraceSink _traceSink;
  int _toolCallCount = 0;

  @override
  Stream<ChatResult<ChatMessage>> sendStream(
    List<ChatMessage> messages, {
    ChatModelOptions? options,
    Schema? outputSchema,
  }) async* {
    final response = await _runtime.generateOnce(
      prompt: _renderPrompt(messages),
      config: _generationConfig,
    );
    final message = _messageFromModelText(response.text);
    yield ChatResult<ChatMessage>(
      output: message,
      messages: <ChatMessage>[message],
      finishReason: FinishReason.stop,
    );
  }

  @override
  void dispose() {}

  String _renderPrompt(List<ChatMessage> messages) {
    final buffer = StringBuffer()
      ..writeln('You are running as a local Gemma model inside this app.')
      ..writeln('You may call tools only by outputting exactly one tag:')
      ..writeln(
        '<tool_call>{"tool":"get_health_summary","arguments":{"period":"today","metrics":["activeEnergy"]}}</tool_call>',
      )
      ..writeln(
        'For today steps, output exactly: <tool_call>{"tool":"get_health_summary","arguments":{"period":"today","metrics":["steps"]}}</tool_call>',
      )
      ..writeln('The JSON keys must be "tool" and "arguments".')
      ..writeln('Do not use "tool_name", "name", "params", or "parameters".')
      ..writeln('Do not include any other text around a tool call.')
      ..writeln('Available tools:');

    for (final tool in tools ?? const <Tool>[]) {
      buffer.writeln('- ${tool.name}: ${tool.description}');
    }

    buffer.writeln();
    for (final message in messages) {
      _writeMessage(buffer, message);
    }

    buffer
      ..writeln()
      ..writeln('If a tool result is available, answer from that result.')
      ..writeln('Assistant:');
    return buffer.toString().trim();
  }

  void _writeMessage(StringBuffer buffer, ChatMessage message) {
    final roleName = switch (message.role) {
      ChatMessageRole.system => 'System',
      ChatMessageRole.user => 'User',
      ChatMessageRole.model => 'Assistant',
    };
    final text = message.text.trim();
    if (text.isNotEmpty) {
      buffer
        ..writeln('$roleName:')
        ..writeln(text)
        ..writeln();
    }
    for (final part in message.parts.whereType<ToolPart>()) {
      switch (part.kind) {
        case ToolPartKind.call:
          buffer
            ..writeln('Assistant tool call:')
            ..writeln(
              jsonEncode(<String, Object?>{
                'tool': part.toolName,
                'arguments': part.arguments ?? <String, Object?>{},
              }),
            )
            ..writeln();
        case ToolPartKind.result:
          buffer
            ..writeln('Tool result from ${part.toolName}:')
            ..writeln(part.result)
            ..writeln();
      }
    }
  }

  ChatMessage _messageFromModelText(String text) {
    final normalized = text.replaceAll('<pad>', '').trim();
    final parsed = _parseToolCall(normalized);
    final toolCall = parsed.toolCall;
    if (toolCall == null) {
      if (parsed.failureStatus != null) {
        _traceSink.record(
          AgentTraceEvent(
            event: 'agent_tool_call_parse_failed',
            status: parsed.failureStatus,
            phase: 'model_output',
          ),
        );
      }
      return ChatMessage.model(normalized);
    }

    _traceSink.record(
      AgentTraceEvent(
        event: 'agent_tool_call_parsed',
        metricNames: _metricNames(toolCall.arguments),
        period: toolCall.arguments['period'] as String?,
        toolName: toolCall.toolName,
        phase: 'model_output',
      ),
    );
    _toolCallCount += 1;
    return ChatMessage.model(
      '',
      parts: <StandardPart>[
        ToolPart.call(
          callId: 'local_gemma_tool_call_$_toolCallCount',
          toolName: toolCall.toolName,
          arguments: toolCall.arguments,
        ),
      ],
    );
  }

  _LocalToolCallParse _parseToolCall(String text) {
    final match = RegExp(
      r'^<tool_call>\s*(.*?)\s*</tool_call>$',
      dotAll: true,
    ).firstMatch(text);
    final payload = match?.group(1) ?? _wholeJsonToolCall(text);
    if (payload == null) {
      return _LocalToolCallParse(
        failureStatus: text.contains('<tool_call>')
            ? 'missing_strict_wrapper'
            : null,
      );
    }

    final decoded = _decodeToolCall(payload);
    if (decoded == null) {
      return const _LocalToolCallParse(failureStatus: 'invalid_json');
    }

    final toolName =
        decoded['tool'] ??
        decoded['tool_name'] ??
        decoded['toolName'] ??
        decoded['name'];
    final arguments = _normalizeArguments(
      decoded['arguments'] ??
          decoded['params'] ??
          decoded['parameters'] ??
          decoded['input'],
    );
    if (toolName is! String || arguments == null) {
      return const _LocalToolCallParse(failureStatus: 'invalid_schema');
    }
    final availableToolNames = (tools ?? const <Tool>[])
        .map((tool) => tool.name)
        .toSet();
    if (!availableToolNames.contains(toolName)) {
      return const _LocalToolCallParse(failureStatus: 'unknown_tool');
    }

    return _LocalToolCallParse(
      toolCall: _LocalToolCall(toolName: toolName, arguments: arguments),
    );
  }

  String? _wholeJsonToolCall(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
      return null;
    }
    if (!trimmed.contains('get_health_summary')) {
      return null;
    }
    return trimmed;
  }

  Map<String, Object?>? _decodeToolCall(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Map<String, Object?>? _normalizeArguments(Object? value) {
    if (value is! Map) {
      return null;
    }
    final normalized = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        return null;
      }
      normalized[key] = entry.value;
    }
    return normalized;
  }

  List<String>? _metricNames(Map<String, Object?> arguments) {
    final metrics = arguments['metrics'];
    if (metrics is! List) {
      return null;
    }
    return metrics.map((metric) => metric.toString()).toList(growable: false);
  }
}

final class _LocalToolCallParse {
  const _LocalToolCallParse({this.toolCall, this.failureStatus});

  final _LocalToolCall? toolCall;
  final String? failureStatus;
}

final class _LocalToolCall {
  const _LocalToolCall({required this.toolName, required this.arguments});

  final String toolName;
  final Map<String, Object?> arguments;
}
