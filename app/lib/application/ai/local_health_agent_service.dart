import 'dart:convert';

import 'package:dartantic_ai/dartantic_ai.dart';

import '../../domain/ai/llm_generation_config.dart';
import '../../domain/ai/llm_runtime.dart';
import '../../domain/health/health_metric_type.dart';
import '../health/health_summary_service.dart';
import '../observability/agent_trace_sink.dart';
import 'local_gemma_provider.dart';

abstract interface class LocalHealthAgentService {
  String budgetPromptFor(String userPrompt);

  Future<String> ask({
    required String prompt,
    required LlmGenerationConfig config,
  });
}

final class DartanticLocalHealthAgentService
    implements LocalHealthAgentService {
  const DartanticLocalHealthAgentService({
    required LlmRuntime runtime,
    required HealthSummaryService healthSummaryService,
    AgentTraceSink traceSink = const NoopAgentTraceSink(),
  }) : _runtime = runtime,
       _healthSummaryService = healthSummaryService,
       _traceSink = traceSink;

  static const String healthSummaryToolName = 'get_health_summary';

  static const String systemPrompt = '''
You are a local wellbeing assistant, not a doctor.
Use tools when the user asks about current, today, or recent Apple Health facts.
If a tool result is available, answer from it.
If a tool result has status ok and metrics are present, answer with those values.
If a tool result has status permission_denied, no_data, unavailable, or invalid_request, explain that exact status clearly.
If status is no_data with reason permission_or_no_visible_data, name the requested metric and say iOS returned no visible data; ask the user to check Health > Sharing > Apps > Gemma Local, enable that data type, and confirm Health contains data for the period.
If HealthKit has no data or permission is missing, say that clearly.
Do not claim you cannot access Apple Health when a tool result is present.
Do not diagnose disease, prescribe medication, or provide medical treatment.
Keep answers concise and user-facing.
''';

  final LlmRuntime _runtime;
  final HealthSummaryService _healthSummaryService;
  final AgentTraceSink _traceSink;

  @override
  String budgetPromptFor(String userPrompt) {
    return '$systemPrompt\n\nUser:\n${userPrompt.trim()}';
  }

  @override
  Future<String> ask({
    required String prompt,
    required LlmGenerationConfig config,
  }) async {
    _traceSink.record(
      const AgentTraceEvent(event: 'agent_start', phase: 'ask'),
    );
    final routedRequest = _routeHealthSummaryRequest(prompt);
    if (routedRequest != null) {
      return _askWithHealthSummary(
        userPrompt: prompt,
        config: config,
        request: routedRequest,
      );
    }
    final agent = Agent.forProvider(
      LocalGemmaProvider(
        runtime: _runtime,
        generationConfig: config,
        traceSink: _traceSink,
      ),
      tools: <Tool<Map<String, dynamic>>>[_healthSummaryTool()],
      chatModelName: 'local-gemma',
      displayName: 'Local Gemma Health Agent',
    );
    final result = await agent.send(
      prompt.trim(),
      history: <ChatMessage>[ChatMessage.system(systemPrompt.trim())],
    );
    _traceSink.record(
      const AgentTraceEvent(event: 'agent_final_answer', phase: 'ask'),
    );
    return result.output;
  }

  Future<String> _askWithHealthSummary({
    required String userPrompt,
    required LlmGenerationConfig config,
    required _HealthSummaryRequest request,
  }) async {
    final result = await _runHealthSummaryTool(
      period: request.period,
      metricNames: request.metrics,
    );
    final response = await _runtime.generateOnce(
      prompt: _finalAnswerPrompt(userPrompt: userPrompt, toolResult: result),
      config: config,
    );
    _traceSink.record(
      const AgentTraceEvent(event: 'agent_final_answer', phase: 'ask'),
    );
    return response.text;
  }

  Tool<Map<String, dynamic>> _healthSummaryTool() {
    return Tool<Map<String, dynamic>>(
      name: healthSummaryToolName,
      description:
          'Read local Apple Health aggregate data after the user has authorized Apple Health once. Supports period today or last24h and metrics steps, sleepSession, workoutSession, activeEnergy, basalEnergy, exerciseTime, standTime, distanceWalkingRunning, flightsClimbed, heartRate, restingHeartRate, walkingHeartRateAverage, hrv, weight, mindfulMinutes.',
      inputSchema: S.object(
        properties: <String, Schema>{
          'period': S.string(),
          'metrics': S.list(items: S.string()),
        },
        required: <String>['period', 'metrics'],
      ),
      onCall: (Map<String, dynamic> input) async {
        final period = input['period'];
        final metrics = input['metrics'];
        if (period is! String || metrics is! List) {
          _traceSink.record(
            const AgentTraceEvent(
              event: 'agent_model_tool_call',
              toolName: healthSummaryToolName,
              status: HealthSummaryService.statusInvalidRequest,
              phase: 'tool_callback',
            ),
          );
          final result = <String, Object?>{
            'status': HealthSummaryService.statusInvalidRequest,
            'reason': HealthSummaryService.reasonInvalidRequest,
            'period': period?.toString() ?? '',
            'metrics': <String, Object?>{},
          };
          _traceSink.record(
            const AgentTraceEvent(
              event: 'agent_tool_result',
              toolName: healthSummaryToolName,
              status: HealthSummaryService.statusInvalidRequest,
              phase: 'tool_callback',
            ),
          );
          return result;
        }
        final metricNames = metrics
            .map((metric) => metric.toString())
            .toList(growable: false);
        return _runHealthSummaryTool(period: period, metricNames: metricNames);
      },
    );
  }

  Future<Map<String, Object?>> _runHealthSummaryTool({
    required String period,
    required List<String> metricNames,
  }) async {
    _traceSink.record(
      AgentTraceEvent(
        event: 'agent_model_tool_call',
        metricNames: metricNames,
        period: period,
        toolName: healthSummaryToolName,
        phase: 'tool_callback',
      ),
    );
    final result = await _healthSummaryService.getHealthSummary(
      period: period,
      metrics: metricNames,
    );
    _traceSink.record(
      AgentTraceEvent(
        event: 'agent_tool_result',
        metricNames: metricNames,
        period: period,
        status: result['status'] as String?,
        sampleCount: _sampleCount(result),
        toolName: healthSummaryToolName,
        phase: 'tool_callback',
      ),
    );
    return result;
  }

  String _finalAnswerPrompt({
    required String userPrompt,
    required Map<String, Object?> toolResult,
  }) {
    return '''
$systemPrompt

User:
${userPrompt.trim()}

Tool result from $healthSummaryToolName:
${jsonEncode(toolResult)}

Answer the user from the tool result. If status is ok and metrics are present, give the metric values directly. If status is no_data with reason permission_or_no_visible_data, name the requested metric and explain that iOS returned no visible data after the app requested access, so the user should check Health > Sharing > Apps > Gemma Local, enable that data type, and confirm Health contains data for the period. Do not say you cannot access Apple Health when status is ok.
Assistant:
''';
  }

  _HealthSummaryRequest? _routeHealthSummaryRequest(String prompt) {
    final text = prompt.trim().toLowerCase();
    final metrics = <String>[];
    if (_containsAny(text, const <String>['步', 'steps', 'walk'])) {
      metrics.add(HealthMetricType.steps.wireName);
    }
    if (_containsAny(text, const <String>[
      '卡路里',
      '消耗',
      'kcal',
      'calorie',
      'active energy',
    ])) {
      metrics.add(HealthMetricType.activeEnergy.wireName);
    }
    if (_containsAny(text, const <String>['心率', 'heart rate'])) {
      metrics.add(HealthMetricType.heartRate.wireName);
    }
    if (_containsAny(text, const <String>['静息心率', 'resting heart'])) {
      metrics
        ..remove(HealthMetricType.heartRate.wireName)
        ..add(HealthMetricType.restingHeartRate.wireName);
    }
    if (_containsAny(text, const <String>['hrv', '心率变异', '心率变异性'])) {
      metrics.add(HealthMetricType.hrv.wireName);
    }
    if (_containsAny(text, const <String>['睡', 'sleep'])) {
      metrics.add(HealthMetricType.sleepSession.wireName);
    }
    if (_containsAny(text, const <String>[
      '运动',
      '健身',
      '锻炼',
      'workout',
      'exercise',
    ])) {
      metrics.add(HealthMetricType.workoutSession.wireName);
    }
    if (_containsAny(text, const <String>['体重', 'weight'])) {
      metrics.add(HealthMetricType.weight.wireName);
    }
    if (_containsAny(text, const <String>['正念', '冥想', 'mindful'])) {
      metrics.add(HealthMetricType.mindfulMinutes.wireName);
    }
    if (_containsAny(text, const <String>['距离', 'distance'])) {
      metrics.add(HealthMetricType.distanceWalkingRunning.wireName);
    }
    if (_containsAny(text, const <String>['楼层', '爬楼', 'flights'])) {
      metrics.add(HealthMetricType.flightsClimbed.wireName);
    }
    if (_containsAny(text, const <String>[
      '全部健康',
      '所有健康',
      '健康概览',
      'overall health',
      'all health',
    ])) {
      metrics
        ..clear()
        ..addAll(HealthMetricType.values.map((metric) => metric.wireName));
    }
    if (metrics.isEmpty) {
      return null;
    }

    final sleepOnly =
        metrics.length == 1 &&
        metrics.single == HealthMetricType.sleepSession.wireName;
    final period =
        sleepOnly ||
            _containsAny(text, const <String>[
              '过去24',
              '24h',
              '24 h',
              '昨晚',
              '最近',
            ])
        ? HealthSummaryService.periodLast24h
        : HealthSummaryService.periodToday;
    return _HealthSummaryRequest(
      period: period,
      metrics: metrics.toList(growable: false),
    );
  }

  bool _containsAny(String text, List<String> needles) {
    for (final needle in needles) {
      if (text.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  int? _sampleCount(Map<String, Object?> summary) {
    final metrics = summary['metrics'];
    if (metrics is! Map) {
      return null;
    }
    var count = 0;
    for (final value in metrics.values) {
      if (value is Map && value['sample_count'] is num) {
        count += (value['sample_count'] as num).round();
      }
    }
    return count == 0 ? null : count;
  }
}

final class _HealthSummaryRequest {
  const _HealthSummaryRequest({required this.period, required this.metrics});

  final String period;
  final List<String> metrics;
}
