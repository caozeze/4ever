import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/health/health_data_gateway.dart';
import '../../application/health/health_prompt_context_service.dart';
import '../../data/health/ios_health_data_gateway.dart';
import 'native_providers.dart';

final healthDataGatewayProvider = Provider<HealthDataGateway>((Ref ref) {
  if (defaultTargetPlatform != TargetPlatform.iOS) {
    return const UnavailableHealthDataGateway(
      'Apple Health is only available on iOS.',
    );
  }
  return IosHealthDataGateway(ref.watch(healthDataApiProvider));
});

final healthPromptContextServiceProvider = Provider<HealthPromptContextService>(
  (Ref ref) {
    return DefaultHealthPromptContextService(
      gateway: ref.watch(healthDataGatewayProvider),
    );
  },
);
