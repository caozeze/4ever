import 'package:gemma_local/application/observability/agent_trace_sink.dart';

final class RecordingAgentTraceSink implements AgentTraceSink {
  final List<AgentTraceEvent> events = <AgentTraceEvent>[];

  @override
  void record(AgentTraceEvent event) {
    events.add(event);
  }

  List<String> get eventNames => events.map((event) => event.event).toList();
}
