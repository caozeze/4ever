abstract interface class AgentTraceSink {
  void record(AgentTraceEvent event);
}

final class AgentTraceEvent {
  const AgentTraceEvent({
    required this.event,
    this.metricNames,
    this.modelId,
    this.errorCode,
    this.period,
    this.status,
    this.sampleCount,
    this.actionCount,
    this.toolName,
    this.phase,
  });

  final String event;
  final List<String>? metricNames;
  final String? modelId;
  final String? errorCode;
  final String? period;
  final String? status;
  final int? sampleCount;
  final int? actionCount;
  final String? toolName;
  final String? phase;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'event': event,
      if (status != null) 'status': status,
      if (phase != null) 'phase': phase,
      if (actionCount != null) 'action_count': actionCount,
      if (metricNames != null) 'metric_names': metricNames,
      if (modelId != null) 'model_id': modelId,
      if (errorCode != null) 'error_code': errorCode,
      if (period != null) 'period': period,
      if (sampleCount != null) 'sample_count': sampleCount,
      if (toolName != null) 'tool_name': toolName,
    };
  }
}

final class NoopAgentTraceSink implements AgentTraceSink {
  const NoopAgentTraceSink();

  @override
  void record(AgentTraceEvent event) {}
}
