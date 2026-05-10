import 'dart:convert';

import '../health/health_summary_service.dart';
import 'health_agent_planner.dart';

final class CompactHealthPromptBuilder {
  const CompactHealthPromptBuilder();

  static const String healthSystemPrompt =
      'You are a local wellbeing assistant.\n'
      'Rules: answer in Chinese, be concise, use only provided health data, '
      'do not diagnose or prescribe, say unavailable/no_data clearly.';

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
    final healthData = _compactHealthData(toolResults);
    return '''
$healthSystemPrompt
Style: ${_styleFor(plan.answerMode)}

User:
${userPrompt.trim()}

Health data:
${jsonEncode(healthData)}

Answer:
'''
        .trim();
  }

  String _styleFor(HealthAgentAnswerMode answerMode) {
    return switch (answerMode) {
      HealthAgentAnswerMode.directMetricAnswer =>
        'answer the requested value first.',
      HealthAgentAnswerMode.metricAdvice =>
        'answer the value first, then give 2 short non-medical suggestions.',
      HealthAgentAnswerMode.overallAdvice =>
        'summarize available data, then give 2 short non-medical suggestions.',
      HealthAgentAnswerMode.generalChat => 'answer briefly.',
    };
  }

  List<Map<String, Object?>> _compactHealthData(
    List<Map<String, Object?>> toolResults,
  ) {
    final compact = <Map<String, Object?>>[];
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
                status: status,
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

  Map<String, Object?> _compactMetric({
    required String metricName,
    required String? period,
    required String? status,
    required Map<dynamic, dynamic> value,
  }) {
    final compact = <String, Object?>{'metric': metricName};
    if (period != null) {
      compact['period'] = period;
    }
    if (status != null) {
      compact['status'] = status;
    }
    for (final key in const <String>[
      'value',
      'average',
      'min',
      'max',
      'unit',
    ]) {
      final metricValue = value[key];
      if (metricValue != null) {
        compact[key] = metricValue;
      }
    }
    compact['as_of'] = value['as_of'] ?? value['sample_end_time'];
    compact.removeWhere((_, metricValue) => metricValue == null);
    return compact;
  }

  Map<String, Object?> _compactUnavailableMetric({
    required String metricName,
    required String? period,
    required String? status,
    required String? reason,
  }) {
    final compact = <String, Object?>{'metric': metricName};
    if (period != null) {
      compact['period'] = period;
    }
    if (status != null) {
      compact['status'] = status;
    }
    if (reason != null) {
      compact['reason'] = reason;
    }
    return compact;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value.map((item) => item.toString()).toList(growable: false);
  }
}
