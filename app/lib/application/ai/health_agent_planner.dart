import '../../domain/health/health_metric_type.dart';
import '../health/health_summary_service.dart';

enum HealthAgentAnswerMode {
  directMetricAnswer,
  metricAdvice,
  overallAdvice,
  generalChat,
}

final class HealthAgentPlanner {
  const HealthAgentPlanner();

  static const todayOverview = <HealthMetricType>[
    HealthMetricType.steps,
    HealthMetricType.activeEnergy,
    HealthMetricType.basalEnergy,
    HealthMetricType.exerciseTime,
    HealthMetricType.standTime,
    HealthMetricType.distanceWalkingRunning,
    HealthMetricType.flightsClimbed,
    HealthMetricType.workoutSession,
  ];
  static const last24hOverview = <HealthMetricType>[
    HealthMetricType.sleepSession,
    HealthMetricType.mindfulMinutes,
  ];
  static const latestOverview = <HealthMetricType>[
    HealthMetricType.heartRate,
    HealthMetricType.restingHeartRate,
    HealthMetricType.walkingHeartRateAverage,
    HealthMetricType.hrv,
    HealthMetricType.weight,
  ];

  static const _latest = <HealthMetricType>{
    HealthMetricType.heartRate,
    HealthMetricType.restingHeartRate,
    HealthMetricType.walkingHeartRateAverage,
    HealthMetricType.hrv,
    HealthMetricType.weight,
  };

  HealthAgentPlan plan(String prompt) {
    final text = prompt.trim().toLowerCase();
    final advice = _has(text, const [
      '建议',
      '怎么办',
      '如何调整',
      'advice',
      'suggest',
      'recommend',
    ]);
    final overview = _isOverviewRequest(text);
    if (overview) {
      return const HealthAgentPlan(
        needsHealthData: true,
        needsAdvice: true,
        answerMode: HealthAgentAnswerMode.overallAdvice,
        actions: [
          HealthAgentAction(
            HealthSummaryService.periodToday,
            todayOverview,
            'today_activity_overview',
          ),
          HealthAgentAction(
            HealthSummaryService.periodLast24h,
            last24hOverview,
            'recent_recovery_overview',
          ),
          HealthAgentAction(
            HealthSummaryService.periodLatest,
            latestOverview,
            'latest_vitals_overview',
          ),
        ],
      );
    }

    final metrics = _metrics(text);
    if (metrics.isEmpty) {
      return const HealthAgentPlan(
        needsHealthData: false,
        needsAdvice: false,
        answerMode: HealthAgentAnswerMode.generalChat,
        actions: [],
      );
    }
    if (advice && metrics.contains(HealthMetricType.activeEnergy)) {
      metrics.addAll([HealthMetricType.steps, HealthMetricType.exerciseTime]);
    }
    return HealthAgentPlan(
      needsHealthData: true,
      needsAdvice: advice,
      answerMode: advice
          ? HealthAgentAnswerMode.metricAdvice
          : HealthAgentAnswerMode.directMetricAnswer,
      actions: _actions(text, metrics),
    );
  }

  Set<HealthMetricType> _metrics(String text) {
    final metrics = <HealthMetricType>{};
    void add(HealthMetricType metric, List<String> words) {
      if (_has(text, words)) metrics.add(metric);
    }

    add(HealthMetricType.steps, const ['步', 'steps', 'walk']);
    add(HealthMetricType.activeEnergy, const [
      '卡路里',
      '消耗',
      'kcal',
      'calorie',
      'active energy',
    ]);
    add(HealthMetricType.basalEnergy, const [
      '总消耗',
      '总热量',
      '全天总',
      'total calorie',
      'total energy',
    ]);
    add(HealthMetricType.hrv, const ['hrv', '心率变异', '心率变异性']);
    add(HealthMetricType.sleepSession, const ['睡', 'sleep']);
    add(HealthMetricType.weight, const ['体重', 'weight']);
    add(HealthMetricType.mindfulMinutes, const ['正念', '冥想', 'mindful']);
    add(HealthMetricType.distanceWalkingRunning, const ['距离', 'distance']);
    add(HealthMetricType.flightsClimbed, const ['楼层', '爬楼', 'flights']);
    if (_has(text, const ['静息心率', 'resting heart'])) {
      metrics.add(HealthMetricType.restingHeartRate);
    } else {
      add(HealthMetricType.heartRate, const ['心率', 'heart rate']);
    }
    if (_has(text, const ['运动时间', '锻炼时间', 'exercise time'])) {
      metrics.add(HealthMetricType.exerciseTime);
    } else {
      add(HealthMetricType.workoutSession, const [
        '运动',
        '健身',
        '锻炼',
        'workout',
        'exercise',
      ]);
    }
    return metrics;
  }

  List<HealthAgentAction> _actions(String text, Set<HealthMetricType> metrics) {
    final asksLatest = _has(text, const [
      '现在',
      '当前',
      'latest',
      'right now',
      'current',
    ]);
    final asksRecent = _has(text, const [
      '过去24',
      '24h',
      '24 h',
      '昨晚',
      '最近',
      'recent',
    ]);
    final today = <HealthMetricType>[];
    final last24h = <HealthMetricType>[];
    final latest = <HealthMetricType>[];
    for (final metric in HealthMetricType.values.where(metrics.contains)) {
      if (_latest.contains(metric) && (asksLatest || !asksRecent)) {
        latest.add(metric);
      } else if (metric == HealthMetricType.sleepSession ||
          metric == HealthMetricType.mindfulMinutes) {
        last24h.add(metric);
      } else {
        today.add(metric);
      }
    }
    return [
      if (today.isNotEmpty)
        HealthAgentAction(
          HealthSummaryService.periodToday,
          today,
          'today_to_now',
        ),
      if (last24h.isNotEmpty)
        HealthAgentAction(
          HealthSummaryService.periodLast24h,
          last24h,
          'last_24_hours',
        ),
      if (latest.isNotEmpty)
        HealthAgentAction(
          HealthSummaryService.periodLatest,
          latest,
          'latest_visible_sample',
        ),
    ];
  }

  bool _isOverviewRequest(String text) {
    if (_has(text, const [
      '当前状态',
      '当前的状态',
      '当前情况',
      '当前的情况',
      '现在状态',
      '现在情况',
      '健康状态',
      '身体状态',
      '全部健康',
      '所有健康',
      '所有数据',
      '所有的数据',
      '全部数据',
      '全部的数据',
      '健康概览',
      '健康数据',
      '我的数据',
      '我的健康',
      '整体健康',
      '整体建议',
      '给我整体健康建议',
      'overall health',
      'health status',
      'current state',
    ])) {
      return true;
    }
    final mentionsHealthContext = _has(text, const ['数据', '健康', '状态', '身体']);
    final asksForAnalysis = _has(text, const [
      '建议',
      '给点建议',
      '分析',
      '分析一下',
      '看看',
      '看一下',
      '怎么样',
      '如何',
    ]);
    return mentionsHealthContext && asksForAnalysis;
  }

  bool _has(String text, List<String> words) => words.any(text.contains);
}

final class HealthAgentPlan {
  const HealthAgentPlan({
    required this.needsHealthData,
    required this.needsAdvice,
    required this.answerMode,
    required this.actions,
  });

  final bool needsHealthData;
  final bool needsAdvice;
  final HealthAgentAnswerMode answerMode;
  final List<HealthAgentAction> actions;

  List<HealthMetricType> get requestedMetrics {
    return <HealthMetricType>{
      for (final action in actions) ...action.metrics,
    }.toList(growable: false);
  }

  Map<String, Object?> toJson() => {
    'needs_health_data': needsHealthData,
    'needs_advice': needsAdvice,
    'answer_mode': answerMode.name,
    'requested_metrics': requestedMetrics
        .map((metric) => metric.wireName)
        .toList(),
    'actions': actions.map((action) => action.toJson()).toList(),
  };
}

final class HealthAgentAction {
  const HealthAgentAction(this.period, this.metrics, this.reason);

  final String period;
  final List<HealthMetricType> metrics;
  final String reason;

  Map<String, Object?> toJson() => {
    'tool': 'get_health_summary',
    'period': period,
    'metrics': metrics.map((metric) => metric.wireName).toList(),
    'reason': reason,
  };
}
