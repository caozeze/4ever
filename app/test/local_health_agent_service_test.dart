import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/ai/local_health_agent_service.dart';
import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/application/health/health_summary_service.dart';
import 'package:gemma_local/domain/ai/llm_generation_config.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

import 'agent_trace_test_support.dart';
import 'health/demo_chat_test_support.dart';
import 'health/health_test_fakes.dart';

void main() {
  test(
    'runs health summary tool and feeds result into second Gemma prompt',
    () async {
      final runtime = RecordingLlmRuntime()
        ..responseTexts.addAll(<String>['You burned 320.5 kcal today.']);
      final gateway = FakeHealthDataGateway()
        ..samples = <HealthDataSample>[
          healthSample(
            type: HealthMetricType.activeEnergy,
            numericValue: 120.2,
            unit: 'kcal',
            start: DateTime(2026, 5, 10, 9),
          ),
          healthSample(
            type: HealthMetricType.activeEnergy,
            numericValue: 200.3,
            unit: 'kcal',
            start: DateTime(2026, 5, 10, 12),
          ),
        ];
      final traceSink = RecordingAgentTraceSink();
      final service = DartanticLocalHealthAgentService(
        runtime: runtime,
        healthSummaryService: HealthSummaryService(
          gateway: gateway,
          traceSink: traceSink,
        ),
        traceSink: traceSink,
      );

      final answer = await service.ask(
        prompt: '我今天消耗了多少卡路里？',
        config: const LlmGenerationConfig(maxTokens: 128),
      );

      expect(answer, contains('320.5 kcal'));
      expect(runtime.generatedPrompts, hasLength(1));
      expect(
        runtime.generatedPrompts.single,
        contains('Tool result from get_health_summary:'),
      );
      expect(runtime.generatedPrompts.single, contains('"activeEnergy"'));
      expect(runtime.generatedPrompts.single, contains('"value":320.5'));
      expect(runtime.generatedPrompts.single, contains('"sample_count":2'));
      expect(gateway.requestedPermissions, <HealthMetricType>{
        HealthMetricType.activeEnergy,
      });
      expect(traceSink.eventNames, <String>[
        'agent_start',
        'agent_model_tool_call',
        'health_summary_read_start',
        'health_summary_read_finish',
        'agent_tool_result',
        'agent_final_answer',
      ]);
      final finishEvent = traceSink.events.singleWhere(
        (event) => event.event == 'health_summary_read_finish',
      );
      expect(finishEvent.status, HealthSummaryService.statusOk);
      expect(finishEvent.metricNames, <String>['activeEnergy']);
      expect(finishEvent.sampleCount, 2);
    },
  );

  test(
    'no-data tool result is passed to final prompt without fabrication',
    () async {
      final runtime = RecordingLlmRuntime()
        ..responseTexts.addAll(<String>[
          'Apple Health has no active energy data for today.',
        ]);
      final traceSink = RecordingAgentTraceSink();
      final service = DartanticLocalHealthAgentService(
        runtime: runtime,
        healthSummaryService: HealthSummaryService(
          gateway: FakeHealthDataGateway(),
          traceSink: traceSink,
        ),
        traceSink: traceSink,
      );

      final answer = await service.ask(
        prompt: '我今天消耗了多少卡路里？',
        config: const LlmGenerationConfig(maxTokens: 128),
      );

      expect(answer, contains('no active energy data'));
      expect(runtime.generatedPrompts.single, contains('"status":"no_data"'));
      expect(
        runtime.generatedPrompts.single,
        contains('"reason":"permission_or_no_data"'),
      );
      final finishEvent = traceSink.events.singleWhere(
        (event) => event.event == 'health_summary_read_finish',
      );
      expect(finishEvent.status, HealthSummaryService.statusNoData);
    },
  );

  test('runs steps tool call and traces health summary status', () async {
    final runtime = RecordingLlmRuntime()
      ..responseTexts.addAll(<String>['You walked 1234 steps today.']);
    final gateway = FakeHealthDataGateway()
      ..samples = <HealthDataSample>[
        healthSample(
          type: HealthMetricType.steps,
          numericValue: 1234,
          unit: 'count',
          start: DateTime(2026, 5, 10, 9),
        ),
      ];
    final traceSink = RecordingAgentTraceSink();
    final service = DartanticLocalHealthAgentService(
      runtime: runtime,
      healthSummaryService: HealthSummaryService(
        gateway: gateway,
        traceSink: traceSink,
      ),
      traceSink: traceSink,
    );

    final answer = await service.ask(
      prompt: '我今天走了多少步？',
      config: const LlmGenerationConfig(maxTokens: 128),
    );

    expect(answer, contains('1234 steps'));
    expect(runtime.generatedPrompts.single, contains('"steps"'));
    expect(runtime.generatedPrompts.single, contains('"value":1234'));
    final toolResult = traceSink.events.singleWhere(
      (event) => event.event == 'agent_tool_result',
    );
    expect(toolResult.status, HealthSummaryService.statusOk);
    expect(toolResult.metricNames, <String>['steps']);
    expect(toolResult.sampleCount, 1);
  });

  test('routes sleep questions to last24h summary', () async {
    final runtime = RecordingLlmRuntime()
      ..responseTexts.add('You slept 6.5 hours recently.');
    final gateway = FakeHealthDataGateway()
      ..aggregates = const <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.sleepSession,
          unit: 'hour',
          sampleCount: 3,
          value: 6.5,
        ),
      ];
    final service = DartanticLocalHealthAgentService(
      runtime: runtime,
      healthSummaryService: HealthSummaryService(gateway: gateway),
    );

    await service.ask(
      prompt: '我昨晚睡了多久？',
      config: const LlmGenerationConfig(maxTokens: 128),
    );

    expect(runtime.generatedPrompts.single, contains('"period":"last24h"'));
    expect(runtime.generatedPrompts.single, contains('"sleepSession"'));
    expect(runtime.generatedPrompts.single, contains('"value":6.5'));
  });
}
