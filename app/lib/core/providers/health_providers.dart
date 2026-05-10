import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/health/health_authorization_service.dart';
import '../../application/health/health_data_gateway.dart';
import '../../application/health/health_summary_service.dart';
import '../../application/observability/agent_trace_sink.dart';
import '../../data/health/ios_health_data_gateway.dart';
import '../logging/console_agent_trace_sink.dart';
import 'native_providers.dart';

final agentTraceSinkProvider = Provider<AgentTraceSink>((Ref ref) {
  return const ConsoleAgentTraceSink();
});

final healthDataGatewayProvider = Provider<HealthDataGateway>((Ref ref) {
  if (defaultTargetPlatform != TargetPlatform.iOS) {
    return const UnavailableHealthDataGateway(
      'Apple Health is only available on iOS.',
    );
  }
  return IosHealthDataGateway(ref.watch(healthDataApiProvider));
});

final healthSummaryServiceProvider = Provider<HealthSummaryService>((Ref ref) {
  return HealthSummaryService(
    gateway: ref.watch(healthDataGatewayProvider),
    traceSink: ref.watch(agentTraceSinkProvider),
  );
});

final healthAuthorizationServiceProvider = Provider<HealthAuthorizationService>(
  (Ref ref) {
    return HealthAuthorizationService(
      gateway: ref.watch(healthDataGatewayProvider),
      healthSummaryService: ref.watch(healthSummaryServiceProvider),
    );
  },
);
