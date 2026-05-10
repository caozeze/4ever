import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/ai/compact_health_prompt_builder.dart';
import 'package:gemma_local/application/ai/health_agent_planner.dart';
import 'package:gemma_local/application/health/health_summary_service.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

void main() {
  const builder = CompactHealthPromptBuilder();

  test('direct metric prompt keeps only compact metric fields', () {
    final prompt = builder.buildHealthPrompt(
      userPrompt: '我今天消耗了多少卡路里？',
      plan: const HealthAgentPlan(
        needsHealthData: true,
        needsAdvice: false,
        answerMode: HealthAgentAnswerMode.directMetricAnswer,
        actions: [
          HealthAgentAction(HealthSummaryService.periodToday, [
            HealthMetricType.activeEnergy,
          ], 'today_to_now'),
        ],
      ),
      toolResults: const <Map<String, Object?>>[
        <String, Object?>{
          'action': <String, Object?>{
            'tool': 'get_health_summary',
            'period': 'today',
            'metrics': <String>['activeEnergy'],
            'reason': 'today_to_now',
          },
          'result': <String, Object?>{
            'status': 'ok',
            'period': 'today',
            'requested_metrics': <String>['activeEnergy'],
            'start_time': '2026-05-11T00:00:00.000',
            'end_time': '2026-05-11T01:00:00.000',
            'metrics': <String, Object?>{
              'activeEnergy': <String, Object?>{
                'value': 320.5,
                'unit': 'kcal',
                'sample_count': 2,
              },
            },
          },
        },
      ],
    );

    expect(prompt, contains('Health data:'));
    expect(prompt, contains('"metric":"activeEnergy"'));
    expect(prompt, contains('"value":320.5'));
    expect(prompt, contains('"unit":"kcal"'));
    expect(prompt, isNot(contains('agent_plan')));
    expect(prompt, isNot(contains('answer_rules')));
    expect(prompt, isNot(contains('requested_metrics')));
    expect(prompt, isNot(contains('sample_count')));
    expect(prompt, isNot(contains('today_to_now')));
    expect(prompt.length, lessThan(700));
  });

  test('overview prompt flattens multiple health result groups', () {
    final prompt = builder.buildHealthPrompt(
      userPrompt: '根据我当前的状态，你看看有什么建议',
      plan: const HealthAgentPlan(
        needsHealthData: true,
        needsAdvice: true,
        answerMode: HealthAgentAnswerMode.overallAdvice,
        actions: [
          HealthAgentAction(HealthSummaryService.periodToday, [
            HealthMetricType.steps,
          ], 'today_activity_overview'),
          HealthAgentAction(HealthSummaryService.periodLatest, [
            HealthMetricType.heartRate,
          ], 'latest_vitals_overview'),
        ],
      ),
      toolResults: const <Map<String, Object?>>[
        <String, Object?>{
          'result': <String, Object?>{
            'status': 'ok',
            'period': 'today',
            'metrics': <String, Object?>{
              'steps': <String, Object?>{
                'value': 3000,
                'unit': 'count',
                'sample_count': 1,
              },
            },
          },
        },
        <String, Object?>{
          'result': <String, Object?>{
            'status': 'ok',
            'period': 'latest',
            'metrics': <String, Object?>{
              'heartRate': <String, Object?>{
                'value': 70,
                'unit': 'bpm',
                'sample_end_time': '2026-05-11T00:30:00.000',
              },
            },
          },
        },
      ],
    );

    expect(prompt, contains('"metric":"steps"'));
    expect(prompt, contains('"metric":"heartRate"'));
    expect(prompt, contains('"as_of":"2026-05-11T00:30:00.000"'));
    expect(prompt, isNot(contains('overallAdvice')));
    expect(prompt, isNot(contains('today_activity_overview')));
    expect(prompt, isNot(contains('latest_vitals_overview')));
  });

  test('no-data and permission-denied statuses are preserved compactly', () {
    final prompt = builder.buildHealthPrompt(
      userPrompt: '我今天步数是多少？',
      plan: const HealthAgentPlan(
        needsHealthData: true,
        needsAdvice: false,
        answerMode: HealthAgentAnswerMode.directMetricAnswer,
        actions: [
          HealthAgentAction(HealthSummaryService.periodToday, [
            HealthMetricType.steps,
          ], 'today_to_now'),
        ],
      ),
      toolResults: const <Map<String, Object?>>[
        <String, Object?>{
          'result': <String, Object?>{
            'status': 'no_data',
            'reason': 'permission_or_no_visible_data',
            'period': 'today',
            'requested_metrics': <String>['steps'],
            'metrics': <String, Object?>{},
          },
        },
        <String, Object?>{
          'result': <String, Object?>{
            'status': 'permission_denied',
            'reason': 'health_permission_missing',
            'period': 'latest',
            'requested_metrics': <String>['hrv'],
            'metrics': <String, Object?>{},
          },
        },
      ],
    );

    expect(prompt, contains('"metric":"steps"'));
    expect(prompt, contains('"status":"no_data"'));
    expect(prompt, contains('"reason":"permission_or_no_visible_data"'));
    expect(prompt, contains('"metric":"hrv"'));
    expect(prompt, contains('"status":"permission_denied"'));
    expect(prompt, isNot(contains('tool_schema')));
  });

  test('general prompt stays short and contains no tool instructions', () {
    final prompt = builder.buildGeneralPrompt(userPrompt: '今天心情一般怎么办？');

    expect(prompt, contains('User:'));
    expect(prompt, contains('Answer:'));
    expect(prompt, isNot(contains('get_health_summary')));
    expect(prompt, isNot(contains('tool_call')));
    expect(prompt.length, lessThan(180));
  });
}
