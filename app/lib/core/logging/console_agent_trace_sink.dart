import '../../application/observability/agent_trace_sink.dart';

final class ConsoleAgentTraceSink implements AgentTraceSink {
  const ConsoleAgentTraceSink();

  @override
  void record(AgentTraceEvent event) {
    final fields = event
        .toJson()
        .entries
        .map((entry) {
          final value = entry.value;
          if (value is Iterable<Object?>) {
            return '${entry.key}=${value.join(',')}';
          }
          return '${entry.key}=$value';
        })
        .join(' ');
    // ignore: avoid_print
    print('[AgentTrace] $fields');
  }
}
