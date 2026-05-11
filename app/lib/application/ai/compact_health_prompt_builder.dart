import 'dart:convert';

import '../health/health_summary_service.dart';
import 'health_agent_planner.dart';

final class CompactHealthPromptBuilder {
  const CompactHealthPromptBuilder();

  static const String healthSystemPrompt =
      'Local wellbeing assistant. Answer in Chinese.\n'
      'Use only Health data. Do not invent. No diagnosis/meds.\n'
      'If no_data, say unavailable.';

  static const String generalSystemPrompt =
      'You are a local wellbeing assistant. Answer briefly in Chinese.';

  String buildGeneralPrompt({required String userPrompt}) {
    return '''
$generalSystemPrompt

User:
${userPrompt.trim()}

Answer:
'''
        .trim();
  }

  String buildHealthPrompt({
    required String userPrompt,
    required HealthAgentPlan plan,
    required List<Map<String, Object?>> toolResults,
  }) {
    final healthData = _compactHealthRows(toolResults);
    return '''
$healthSystemPrompt
Style: ${_styleFor(plan.answerMode)}

User:
${userPrompt.trim()}

Health data rows:
Rows=[metric,period,value,unit,time]; no_data rows use value=no_data.
${jsonEncode(healthData)}

Answer:
'''
        .trim();
  }

  String _styleFor(HealthAgentAnswerMode answerMode) {
    return switch (answerMode) {
      HealthAgentAnswerMode.directMetricAnswer => 'Value first.',
      HealthAgentAnswerMode.metricAdvice => 'Value first; 2 tips.',
      HealthAgentAnswerMode.overallAdvice => 'Summary; 2 tips.',
      HealthAgentAnswerMode.generalChat => 'Brief.',
    };
  }

  List<List<Object?>> _compactHealthRows(
    List<Map<String, Object?>> toolResults,
  ) {
    final compact = <List<Object?>>[];
    for (final toolResult in toolResults) {
      final result = toolResult['result'];
      if (result is! Map) {
        continue;
      }
      final period = result['period']?.toString();
      final status = result['status']?.toString();
      final metrics = result['metrics'];
      final emittedMetrics = <String>{};
      if (metrics is Map) {
        for (final entry in metrics.entries) {
          final metricName = entry.key.toString();
          emittedMetrics.add(metricName);
          final value = entry.value;
          if (value is Map) {
            compact.add(
              _compactMetric(
                metricName: metricName,
                period: period,
                value: value,
              ),
            );
          }
        }
      }

      final missingMetrics = _stringList(result['missing_metrics']);
      for (final metricName in missingMetrics) {
        if (emittedMetrics.add(metricName)) {
          compact.add(
            _compactUnavailableMetric(
              metricName: metricName,
              period: period,
              status: HealthSummaryService.statusNoData,
              reason: 'missing_metric',
            ),
          );
        }
      }

      if (compact.isEmpty || metrics is! Map || metrics.isEmpty) {
        final requestedMetrics = _stringList(result['requested_metrics']);
        for (final metricName in requestedMetrics) {
          if (emittedMetrics.add(metricName)) {
            compact.add(
              _compactUnavailableMetric(
                metricName: metricName,
                period: period,
                status: status,
                reason: result['reason']?.toString(),
              ),
            );
          }
        }
      }
    }
    return compact;
  }

  List<Object?> _compactMetric({
    required String metricName,
    required String? period,
    required Map<dynamic, dynamic> value,
  }) {
    final metricValue = value['value'] ?? value['average'];
    final asOf = period == HealthSummaryService.periodLatest
        ? value['as_of'] ?? value['sample_end_time']
        : null;
    return _trimTrailingNulls(<Object?>[
      _compactMetricName(metricName),
      _compactPeriod(period),
      metricValue,
      value['unit'],
      _compactTime(asOf),
    ]);
  }

  List<Object?> _compactUnavailableMetric({
    required String metricName,
    required String? period,
    required String? status,
    required String? reason,
  }) {
    return _trimTrailingNulls(<Object?>[
      _compactMetricName(metricName),
      _compactPeriod(period),
      status,
      _compactReason(reason),
    ]);
  }

  String _compactMetricName(String metricName) {
    return switch (metricName) {
      'activeEnergy' => 'activeKcal',
      'basalEnergy' => 'basalKcal',
      'distanceWalkingRunning' => 'distance',
      'exerciseTime' => 'exercise',
      'flightsClimbed' => 'floors',
      'heartRate' => 'heartRate',
      'hrv' => 'hrv',
      'mindfulMinutes' => 'mindful',
      'restingHeartRate' => 'restingHR',
      'sleepSession' => 'sleep',
      'standTime' => 'stand',
      'steps' => 'steps',
      'walkingHeartRateAverage' => 'walkingHR',
      'weight' => 'weight',
      'workoutSession' => 'workout',
      _ => metricName,
    };
  }

  String? _compactPeriod(String? period) {
    return switch (period) {
      HealthSummaryService.periodToday => 'today',
      HealthSummaryService.periodLast24h => '24h',
      HealthSummaryService.periodLatest => 'latest',
      _ => period,
    };
  }

  String? _compactReason(String? reason) {
    return switch (reason) {
      'permission_or_no_visible_data' => 'unavailable',
      'missing_metric' => 'missing',
      _ => reason,
    };
  }

  String? _compactTime(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) {
      return null;
    }
    if (text.length >= 16 && text.contains('T')) {
      return text.substring(5, 16);
    }
    return text;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value.map((item) => item.toString()).toList(growable: false);
  }

  List<Object?> _trimTrailingNulls(List<Object?> row) {
    var end = row.length;
    while (end > 0 && row[end - 1] == null) {
      end -= 1;
    }
    return row.sublist(0, end);
  }
}
