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
        ..aggregates = const <HealthDataAggregate>[
          HealthDataAggregate(
            type: HealthMetricType.activeEnergy,
            unit: 'kcal',
            sampleCount: 2,
            value: 320.5,
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
      final generatedPrompt = runtime.generatedPrompts.single;
      expect(generatedPrompt, contains('Health data:'));
      expect(
        generatedPrompt,
        isNot(contains('Structured local health agent input:')),
      );
      expect(generatedPrompt, isNot(contains('"agent_plan"')));
      expect(generatedPrompt, isNot(contains('"tool_results"')));
      expect(generatedPrompt, contains('"metric":"activeEnergy"'));
      expect(generatedPrompt, contains('"value":320.5'));
      expect(generatedPrompt, isNot(contains('"sample_count":2')));
      expect(generatedPrompt.length, lessThan(800));
      expect(gateway.requestedPermissions, isNull);
      expect(traceSink.eventNames, <String>[
        'agent_start',
        'agent_plan',
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
        contains('"reason":"permission_or_no_visible_data"'),
      );
      expect(
        runtime.generatedPrompts.single,
        isNot(contains('"requested_metrics"')),
      );
      final finishEvent = traceSink.events.singleWhere(
        (event) => event.event == 'health_summary_read_finish',
      );
      expect(finishEvent.status, HealthSummaryService.statusNoData);
    },
  );

  test('routes current heart rate questions to latest summary', () async {
    final runtime = RecordingLlmRuntime()
      ..responseTexts.addAll(<String>[
        'Apple Health latest visible heart rate is 72 bpm.',
      ]);
    final gateway = FakeHealthDataGateway()
      ..aggregates = <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.heartRate,
          unit: 'bpm',
          sampleCount: 1,
          value: 72,
          sampleEndTime: DateTime(2026, 5, 10, 15, 25),
        ),
      ];
    final service = DartanticLocalHealthAgentService(
      runtime: runtime,
      healthSummaryService: HealthSummaryService(gateway: gateway),
    );

    await service.ask(
      prompt: '我现在心率多少？',
      config: const LlmGenerationConfig(maxTokens: 128),
    );

    expect(gateway.aggregateReadModes, <String>['latest']);
    expect(runtime.generatedPrompts.single, contains('"period":"latest"'));
    expect(runtime.generatedPrompts.single, contains('"metric":"heartRate"'));
    expect(runtime.generatedPrompts.single, contains('"as_of"'));
  });

  test('routes current state advice to overview action groups', () async {
    final runtime = RecordingLlmRuntime()
      ..responseTexts.addAll(<String>['Here is a local wellbeing summary.']);
    final gateway = FakeHealthDataGateway()
      ..aggregates = const <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.steps,
          unit: 'count',
          sampleCount: 1,
          value: 3000,
        ),
        HealthDataAggregate(
          type: HealthMetricType.heartRate,
          unit: 'bpm',
          sampleCount: 1,
          value: 70,
        ),
      ];
    final service = DartanticLocalHealthAgentService(
      runtime: runtime,
      healthSummaryService: HealthSummaryService(gateway: gateway),
    );

    await service.ask(
      prompt: '根据我当前的状态，你看看有什么建议',
      config: const LlmGenerationConfig(maxTokens: 128),
    );

    expect(gateway.aggregateReadModes, <String>[
      'aggregate',
      'aggregate',
      'latest',
    ]);
    expect(runtime.generatedPrompts.single, isNot(contains('"overallAdvice"')));
    expect(
      runtime.generatedPrompts.single,
      isNot(contains('"today_activity_overview"')),
    );
    expect(runtime.generatedPrompts.single, contains('"metric":"steps"'));
    expect(runtime.generatedPrompts.single, contains('"metric":"heartRate"'));
  });

  test('general chat uses a short direct prompt without tool schema', () async {
    final runtime = RecordingLlmRuntime()
      ..responseTexts.addAll(<String>['Try taking a short walk.']);
    final service = DartanticLocalHealthAgentService(
      runtime: runtime,
      healthSummaryService: HealthSummaryService(
        gateway: FakeHealthDataGateway(),
      ),
    );

    final answer = await service.ask(
      prompt: '今天心情一般怎么办？',
      config: const LlmGenerationConfig(maxTokens: 128),
    );

    expect(answer, contains('short walk'));
    expect(runtime.generatedPrompts.single, contains('User:'));
    expect(runtime.generatedPrompts.single, contains('Answer:'));
    expect(runtime.generatedPrompts.single, isNot(contains('tool_call')));
    expect(
      runtime.generatedPrompts.single,
      isNot(contains('get_health_summary')),
    );
    expect(runtime.generatedPrompts.single.length, lessThan(180));
  });
}
