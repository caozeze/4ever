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
