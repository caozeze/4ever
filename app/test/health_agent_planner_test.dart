import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/ai/health_agent_planner.dart';
import 'package:gemma_local/application/health/health_summary_service.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

void main() {
  const planner = HealthAgentPlanner();

  test('plans overview advice as three health reads', () {
    final plan = planner.plan('根据我当前的状态，你看看有什么建议');

    expect(plan.answerMode, HealthAgentAnswerMode.overallAdvice);
    expect(plan.actions.map((action) => action.period), <String>[
      HealthSummaryService.periodToday,
      HealthSummaryService.periodLast24h,
      HealthSummaryService.periodLatest,
    ]);
  });

  test('plans natural all-data health advice requests as overview', () {
    const prompts = <String>[
      '看看我所有数据，给出建议',
      '看看我所有的数据，给出建议',
      '分析一下我的健康数据',
      '我的数据怎么样',
      '我的健康怎么样',
      '给我整体健康建议',
    ];

    for (final prompt in prompts) {
      final plan = planner.plan(prompt);

      expect(plan.needsHealthData, isTrue, reason: prompt);
      expect(
        plan.answerMode,
        HealthAgentAnswerMode.overallAdvice,
        reason: prompt,
      );
      expect(plan.actions.map((action) => action.period), <String>[
        HealthSummaryService.periodToday,
        HealthSummaryService.periodLast24h,
        HealthSummaryService.periodLatest,
      ], reason: prompt);
    }
  });

  test('keeps ordinary mood chat on the short general path', () {
    final plan = planner.plan('今天心情一般怎么办');

    expect(plan.needsHealthData, isFalse);
    expect(plan.answerMode, HealthAgentAnswerMode.generalChat);
    expect(plan.actions, isEmpty);
  });

  test('plans metric advice for steps and calories', () {
    final plan = planner.plan('我现在步数多少和卡路里多少，你有什么建议');

    expect(plan.answerMode, HealthAgentAnswerMode.metricAdvice);
    expect(plan.actions.single.period, HealthSummaryService.periodToday);
    expect(plan.actions.single.metrics, <HealthMetricType>[
      HealthMetricType.steps,
      HealthMetricType.activeEnergy,
      HealthMetricType.exerciseTime,
    ]);
  });

  test('plans latest vitals and total calories', () {
    final vitals = planner.plan('我现在 hrv 和心率多少');
    expect(vitals.actions.single.period, HealthSummaryService.periodLatest);
    expect(vitals.actions.single.metrics, <HealthMetricType>[
      HealthMetricType.heartRate,
      HealthMetricType.hrv,
    ]);

    final calories = planner.plan('我今天全天总热量消耗是多少');
    expect(calories.actions.single.metrics, <HealthMetricType>[
      HealthMetricType.activeEnergy,
      HealthMetricType.basalEnergy,
    ]);
  });
}
