import 'dart:convert';

import 'package:dartantic_ai/dartantic_ai.dart';

import '../../domain/ai/llm_generation_config.dart';
import '../../domain/ai/llm_runtime.dart';
import '../../domain/health/health_metric_type.dart';
import '../health/health_summary_service.dart';
import '../observability/agent_trace_sink.dart';
import 'health_agent_planner.dart';
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
    HealthAgentPlanner planner = const HealthAgentPlanner(),
    AgentTraceSink traceSink = const NoopAgentTraceSink(),
  }) : _runtime = runtime,
       _healthSummaryService = healthSummaryService,
       _planner = planner,
       _traceSink = traceSink;

  static const String healthSummaryToolName = 'get_health_summary';

  static const String systemPrompt = '''
You are a privacy-first personal health assistant running locally on this device.
You are a local wellbeing assistant, not a doctor.
Use Apple Health tools when the user asks about current, today, recent, or latest health facts.
If a tool result is available, answer from it.
If a tool result has status ok and metrics are present, answer with those values.
If a tool result has status permission_denied, no_data, unavailable, or invalid_request, explain that exact status clearly.
If status is no_data with reason permission_or_no_visible_data, name the requested metric and say iOS returned no visible data; ask the user to check Health > Sharing > Apps > Gemma Local, enable that data type, and confirm Health contains data for the period.
If HealthKit has no data or permission is missing, say that clearly.
Do not claim you cannot access Apple Health when a tool result is present.
Do not invent health values; only use the user request and local Apple Health tool results.
Do not diagnose disease, prescribe medication, or provide medical treatment.
Keep answers concise and user-facing.
''';

  final LlmRuntime _runtime;
  final HealthSummaryService _healthSummaryService;
  final HealthAgentPlanner _planner;
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
    final plan = _planner.plan(prompt);
    _traceSink.record(
      AgentTraceEvent(
        event: 'agent_plan',
        metricNames: plan.requestedMetrics
            .map((metric) => metric.wireName)
            .toList(growable: false),
        status: plan.answerMode.name,
        phase: 'plan',
      ),
    );
    if (plan.needsHealthData) {
      return _askWithHealthPlan(userPrompt: prompt, config: config, plan: plan);
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

  Future<String> _askWithHealthPlan({
    required String userPrompt,
    required LlmGenerationConfig config,
    required HealthAgentPlan plan,
  }) async {
    final toolResults = <Map<String, Object?>>[];
    for (final action in plan.actions) {
      final result = await _runHealthSummaryTool(
        period: action.period,
        metricNames: action.metrics
            .map((metric) => metric.wireName)
            .toList(growable: false),
      );
      toolResults.add(<String, Object?>{
        'action': action.toJson(),
        'result': result,
      });
    }
    final response = await _runtime.generateOnce(
      prompt: _finalAnswerPrompt(
        userPrompt: userPrompt,
        plan: plan,
        toolResults: toolResults,
      ),
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
          'Read local Apple Health aggregate data after the user has authorized Apple Health once. Supports period today, last24h, or latest and metrics steps, sleepSession, workoutSession, activeEnergy, basalEnergy, exerciseTime, standTime, distanceWalkingRunning, flightsClimbed, heartRate, restingHeartRate, walkingHeartRateAverage, hrv, weight, mindfulMinutes.',
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
    required HealthAgentPlan plan,
    required List<Map<String, Object?>> toolResults,
  }) {
    final payload = <String, Object?>{
      'user_request': userPrompt.trim(),
      'agent_plan': plan.toJson(),
      'tool_results': toolResults,
      'answer_rules': <String>[
        'Answer in Chinese unless the user clearly used another language.',
        'Use only the Apple Health tool results and the user request for health facts.',
        'If status is ok, quote the available metric values, units, and time window.',
        'If period is latest, explain that the value is Apple Health latest visible sample, not real-time monitoring.',
        'If missing_metrics is present, say those metrics returned no visible data and continue with available metrics.',
        'If all results are no_data, permission_denied, unavailable, or invalid_request, explain the exact status and do not invent values.',
        'For directMetricAnswer, answer the requested value first and avoid extra advice.',
        'For overallAdvice, start with a short available-data overview, then give practical suggestions.',
        'For advice requests, give 2-4 practical non-medical wellbeing suggestions based on available values.',
        'Do not diagnose disease, prescribe medication, or provide medical treatment.',
      ],
    };
    return '''
$systemPrompt

Structured local health agent input:
${jsonEncode(payload)}

Assistant:
''';
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
