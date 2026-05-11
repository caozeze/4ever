import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../../application/observability/agent_trace_sink.dart';

final class ConsoleAgentTraceSink implements AgentTraceSink {
  const ConsoleAgentTraceSink();

  static const MethodChannel _nativeLogChannel = MethodChannel(
    'com.gemmalocal.gemmaLocal/agent_trace_log',
  );

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
    final line = '[AgentTrace] $fields';
    developer.log(line, name: 'AgentTrace');
    unawaited(
      _nativeLogChannel
          .invokeMethod<void>('log', <String, Object?>{'line': line})
          .catchError((Object _) {}),
    );
    // ignore: avoid_print
    print(line);
  }
}
