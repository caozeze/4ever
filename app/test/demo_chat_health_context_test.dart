import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/application/health/health_prompt_context_service.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

import 'health/demo_chat_test_support.dart';
import 'health/health_test_fakes.dart';

void main() {
  test(
    'demo chat injects aggregated Apple Health context without raw ids',
    () async {
      final runtime = RecordingLlmRuntime();
      final gateway = FakeHealthDataGateway()
        ..samples = <HealthDataSample>[
          healthSample(
            type: HealthMetricType.steps,
            numericValue: 7200,
            unit: 'count',
            textValue: 'HK-raw-id-steps-1',
          ),
          healthSample(
            type: HealthMetricType.sleepSession,
            numericValue: 7.25,
            unit: 'hour',
            textValue: 'HK-raw-id-sleep-1',
          ),
          healthSample(
            type: HealthMetricType.heartRate,
            numericValue: 80,
            unit: 'bpm',
          ),
        ];
      final controller = testDemoChatController(
        runtime: runtime,
        healthPromptContextService: DefaultHealthPromptContextService(
          gateway: gateway,
        ),
      );

      await controller.ask(prompt: 'What should I focus on today?');

      final generatedPrompt = runtime.generatedPrompts.single;
      expect(generatedPrompt, contains('local, privacy-first wellbeing coach'));
      expect(generatedPrompt, contains('Local Apple Health aggregate:'));
      expect(
        generatedPrompt,
        contains('Do not say that you cannot access health data'),
      );
      expect(
        generatedPrompt,
        contains('Apple Health aggregate for the last 24 hours:'),
      );
      expect(generatedPrompt, contains('steps: 7200'));
      expect(generatedPrompt, contains('sleep: 7.3 hours'));
      expect(generatedPrompt, contains('heart rate average: 80 bpm'));
      expect(generatedPrompt, isNot(contains('HK-raw-id')));
      expect(generatedPrompt, isNot(contains('start_time')));
      expect(
        gateway.requestedPermissions,
        DefaultHealthPromptContextService.chatMetricTypes,
      );
      expect(
        gateway.readMetricTypes,
        DefaultHealthPromptContextService.chatMetricTypes,
      );
      expect(
        gateway.readEnd!.difference(gateway.readStart!),
        const Duration(hours: 24),
      );
    },
  );

  test('demo chat still works when Apple Health is unavailable', () async {
    final runtime = RecordingLlmRuntime();
    final controller = testDemoChatController(
      runtime: runtime,
      healthPromptContextService: DefaultHealthPromptContextService(
        gateway: FakeHealthDataGateway()..available = false,
      ),
    );

    await controller.ask(prompt: 'What should I focus on today?');

    final generatedPrompt = runtime.generatedPrompts.single;
    expect(generatedPrompt, 'What should I focus on today?');
    expect(generatedPrompt, isNot(contains('steps:')));
  });
}
