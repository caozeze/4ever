import '../../domain/ai/llm_generation_config.dart';
import '../../domain/ai/llm_runtime.dart';
import '../../domain/health/health_metric_type.dart';
import '../health/health_summary_service.dart';
import '../observability/agent_trace_sink.dart';
import 'compact_health_prompt_builder.dart';
import 'health_agent_planner.dart';

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
    CompactHealthPromptBuilder promptBuilder =
        const CompactHealthPromptBuilder(),
    AgentTraceSink traceSink = const NoopAgentTraceSink(),
  }) : _runtime = runtime,
       _healthSummaryService = healthSummaryService,
       _planner = planner,
       _promptBuilder = promptBuilder,
       _traceSink = traceSink;

  static const String healthSummaryToolName = 'get_health_summary';

  final LlmRuntime _runtime;
  final HealthSummaryService _healthSummaryService;
  final HealthAgentPlanner _planner;
  final CompactHealthPromptBuilder _promptBuilder;
  final AgentTraceSink _traceSink;

  @override
  String budgetPromptFor(String userPrompt) {
    return _promptBuilder.buildGeneralPrompt(userPrompt: userPrompt);
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
    final response = await _runtime.generateOnce(
      prompt: _promptBuilder.buildGeneralPrompt(userPrompt: prompt),
      config: config,
    );
    _traceSink.record(
      const AgentTraceEvent(event: 'agent_final_answer', phase: 'ask'),
    );
    return response.text;
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
      prompt: _promptBuilder.buildHealthPrompt(
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
