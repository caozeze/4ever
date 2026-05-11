import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/ai/local_health_agent_service.dart';
import 'package:gemma_local/domain/ai/llm_generation_config.dart';

import 'health/demo_chat_test_support.dart';

void main() {
  test('demo chat asks local health agent after model is ready', () async {
    final runtime = RecordingLlmRuntime();
    final agent = _RecordingLocalHealthAgentService(
      responseText: 'You burned 320.5 kcal today.',
    );
    final controller = testDemoChatController(
      runtime: runtime,
      localHealthAgentService: agent,
    );

    final response = await controller.ask(prompt: '我今天消耗了多少卡路里？');

    expect(response.text, 'You burned 320.5 kcal today.');
    expect(agent.prompts, <String>['我今天消耗了多少卡路里？']);
    expect(agent.configs.single.maxTokens, greaterThan(16));
    expect(runtime.generatedPrompts, isEmpty);
  });

  test('demo chat does not continue unexecuted tool-call text', () async {
    final runtime = RecordingLlmRuntime();
    final agent = _RecordingLocalHealthAgentService(
      responseText:
          '<tool_call>{"tool":"get_health_summary","arguments":{"period":"today","metrics":["steps"]}}</tool_call>',
    );
    final controller = testDemoChatController(
      runtime: runtime,
      localHealthAgentService: agent,
    );

    await expectLater(
      controller.ask(prompt: '我今天走了多少步？'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Gemma returned an unexecuted tool call.',
        ),
      ),
    );

    expect(runtime.generatedPrompts, isEmpty);
  });
}

final class _RecordingLocalHealthAgentService
    implements LocalHealthAgentService {
  _RecordingLocalHealthAgentService({required this.responseText});

  final String responseText;
  final List<String> prompts = <String>[];
  final List<LlmGenerationConfig> configs = <LlmGenerationConfig>[];

  @override
  String budgetPromptFor(String userPrompt) {
    return 'system\n$userPrompt';
  }

  @override
  Future<String> ask({
    required String prompt,
    required LlmGenerationConfig config,
  }) async {
    prompts.add(prompt);
    configs.add(config);
    return responseText;
  }
}
