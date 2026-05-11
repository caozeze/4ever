import 'package:dartantic_ai/dartantic_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/ai/local_gemma_provider.dart';
import 'package:gemma_local/domain/ai/llm_generation_config.dart';

import 'agent_trace_test_support.dart';
import 'health/demo_chat_test_support.dart';

void main() {
  test('strict tool-call output is converted into ToolPart.call', () async {
    final runtime = RecordingLlmRuntime()
      ..responseText =
          '<tool_call>{"tool":"get_health_summary","arguments":{"period":"today","metrics":["activeEnergy"]}}</tool_call>';
    final traceSink = RecordingAgentTraceSink();
    final model = LocalGemmaChatModel(
      runtime: runtime,
      generationConfig: const LlmGenerationConfig(),
      name: 'local-gemma',
      traceSink: traceSink,
      tools: <Tool>[
        Tool<Map<String, dynamic>>(
          name: 'get_health_summary',
          description: 'Read local health summary.',
          onCall: (_) => <String, Object?>{},
        ),
      ],
    );

    final result = await model.sendStream(<ChatMessage>[
      ChatMessage.user('今天消耗多少卡路里？'),
    ]).single;

    expect(result.output.hasToolCalls, isTrue);
    final toolCall = result.output.toolCalls.single;
    expect(toolCall.toolName, 'get_health_summary');
    expect(toolCall.arguments?['period'], 'today');
    expect(toolCall.arguments?['metrics'], <Object?>['activeEnergy']);
    expect(traceSink.eventNames, contains('agent_tool_call_parsed'));
    final event = traceSink.events.singleWhere(
      (event) => event.event == 'agent_tool_call_parsed',
    );
    expect(event.toolName, 'get_health_summary');
    expect(event.metricNames, <String>['activeEnergy']);
    expect(event.period, 'today');
  });

  test('invalid tool-call JSON is treated as normal text', () async {
    final runtime = RecordingLlmRuntime()
      ..responseText =
          '<tool_call>{"tool":"get_health_summary","arguments":</tool_call>';
    final traceSink = RecordingAgentTraceSink();
    final model = LocalGemmaChatModel(
      runtime: runtime,
      generationConfig: const LlmGenerationConfig(),
      name: 'local-gemma',
      traceSink: traceSink,
      tools: <Tool>[
        Tool<Map<String, dynamic>>(
          name: 'get_health_summary',
          description: 'Read local health summary.',
          onCall: (_) => <String, Object?>{},
        ),
      ],
    );

    final result = await model.sendStream(<ChatMessage>[
      ChatMessage.user('今天消耗多少卡路里？'),
    ]).single;

    expect(result.output.hasToolCalls, isFalse);
    expect(result.output.text, contains('<tool_call>'));
    expect(traceSink.eventNames, contains('agent_tool_call_parse_failed'));
    final event = traceSink.events.singleWhere(
      (event) => event.event == 'agent_tool_call_parse_failed',
    );
    expect(event.status, 'invalid_json');
  });

  test(
    'invalid tool-call schema is traced and treated as normal text',
    () async {
      final runtime = RecordingLlmRuntime()
        ..responseText = '<tool_call>{"tool":"get_health_summary"}</tool_call>';
      final traceSink = RecordingAgentTraceSink();
      final model = LocalGemmaChatModel(
        runtime: runtime,
        generationConfig: const LlmGenerationConfig(),
        name: 'local-gemma',
        traceSink: traceSink,
        tools: <Tool>[
          Tool<Map<String, dynamic>>(
            name: 'get_health_summary',
            description: 'Read local health summary.',
            onCall: (_) => <String, Object?>{},
          ),
        ],
      );

      final result = await model.sendStream(<ChatMessage>[
        ChatMessage.user('今天消耗多少卡路里？'),
      ]).single;

      expect(result.output.hasToolCalls, isFalse);
      final event = traceSink.events.singleWhere(
        (event) => event.event == 'agent_tool_call_parse_failed',
      );
      expect(event.status, 'invalid_schema');
    },
  );

  test('tool-call JSON may be wrapped by whitespace inside tag', () async {
    final runtime = RecordingLlmRuntime()
      ..responseText = '''
<tool_call>
{"tool":"get_health_summary","arguments":{"period":"today","metrics":["steps"]}}
</tool_call>
''';
    final model = LocalGemmaChatModel(
      runtime: runtime,
      generationConfig: const LlmGenerationConfig(),
      name: 'local-gemma',
      tools: <Tool>[
        Tool<Map<String, dynamic>>(
          name: 'get_health_summary',
          description: 'Read local health summary.',
          onCall: (_) => <String, Object?>{},
        ),
      ],
    );

    final result = await model.sendStream(<ChatMessage>[
      ChatMessage.user('今天步数是多少？'),
    ]).single;

    expect(result.output.hasToolCalls, isTrue);
    expect(result.output.toolCalls.single.arguments?['metrics'], <Object?>[
      'steps',
    ]);
  });

  test('tool_name and params tool-call keys are normalized', () async {
    final runtime = RecordingLlmRuntime()
      ..responseText =
          '<tool_call>{"tool_name":"get_health_summary","params":{"period":"today","metrics":["activeEnergy"]}}</tool_call>';
    final model = LocalGemmaChatModel(
      runtime: runtime,
      generationConfig: const LlmGenerationConfig(),
      name: 'local-gemma',
      tools: <Tool>[
        Tool<Map<String, dynamic>>(
          name: 'get_health_summary',
          description: 'Read local health summary.',
          onCall: (_) => <String, Object?>{},
        ),
      ],
    );

    final result = await model.sendStream(<ChatMessage>[
      ChatMessage.user('今天消耗多少卡路里？'),
    ]).single;

    expect(result.output.hasToolCalls, isTrue);
    final toolCall = result.output.toolCalls.single;
    expect(toolCall.toolName, 'get_health_summary');
    expect(toolCall.arguments?['period'], 'today');
    expect(toolCall.arguments?['metrics'], <Object?>['activeEnergy']);
  });

  test('name and parameters tool-call keys are normalized', () async {
    final runtime = RecordingLlmRuntime()
      ..responseText =
          '<tool_call>{"name":"get_health_summary","parameters":{"period":"today","metrics":["steps"]}}</tool_call>';
    final model = LocalGemmaChatModel(
      runtime: runtime,
      generationConfig: const LlmGenerationConfig(),
      name: 'local-gemma',
      tools: <Tool>[
        Tool<Map<String, dynamic>>(
          name: 'get_health_summary',
          description: 'Read local health summary.',
          onCall: (_) => <String, Object?>{},
        ),
      ],
    );

    final result = await model.sendStream(<ChatMessage>[
      ChatMessage.user('今天走了多少步？'),
    ]).single;

    expect(result.output.hasToolCalls, isTrue);
    final toolCall = result.output.toolCalls.single;
    expect(toolCall.toolName, 'get_health_summary');
    expect(toolCall.arguments?['period'], 'today');
    expect(toolCall.arguments?['metrics'], <Object?>['steps']);
  });

  test(
    'whole JSON tool-call output is parsed when it names the health tool',
    () async {
      final runtime = RecordingLlmRuntime()
        ..responseText =
            '{"tool":"get_health_summary","arguments":{"period":"today","metrics":["steps"]}}';
      final model = LocalGemmaChatModel(
        runtime: runtime,
        generationConfig: const LlmGenerationConfig(),
        name: 'local-gemma',
        tools: <Tool>[
          Tool<Map<String, dynamic>>(
            name: 'get_health_summary',
            description: 'Read local health summary.',
            onCall: (_) => <String, Object?>{},
          ),
        ],
      );

      final result = await model.sendStream(<ChatMessage>[
        ChatMessage.user('今天走了多少步？'),
      ]).single;

      expect(result.output.hasToolCalls, isTrue);
      final toolCall = result.output.toolCalls.single;
      expect(toolCall.toolName, 'get_health_summary');
      expect(toolCall.arguments?['metrics'], <Object?>['steps']);
    },
  );

  test('unknown tool call is treated as normal text', () async {
    final runtime = RecordingLlmRuntime()
      ..responseText =
          '<tool_call>{"tool":"unknown","arguments":{"period":"today"}}</tool_call>';
    final model = LocalGemmaChatModel(
      runtime: runtime,
      generationConfig: const LlmGenerationConfig(),
      name: 'local-gemma',
      tools: <Tool>[
        Tool<Map<String, dynamic>>(
          name: 'get_health_summary',
          description: 'Read local health summary.',
          onCall: (_) => <String, Object?>{},
        ),
      ],
    );

    final result = await model.sendStream(<ChatMessage>[
      ChatMessage.user('今天消耗多少卡路里？'),
    ]).single;

    expect(result.output.hasToolCalls, isFalse);
    expect(result.output.text, contains('"unknown"'));
  });
}
