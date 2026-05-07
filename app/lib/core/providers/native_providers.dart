import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ai/llm_runtime.dart';
import '../native/debug_http_llm_runtime.dart';
import '../native/ios_background_task_api.dart';
import '../native/ios_crypto_api.dart';
import '../native/ios_health_data_api.dart';
import '../native/ios_llm_runtime.dart';

final llmRuntimeProvider = Provider<LlmRuntime>((Ref ref) {
  const debugRuntimeUrl = String.fromEnvironment(
    'GEMMA_MVP_REMOTE_RUNTIME_URL',
  );
  if (debugRuntimeUrl.isNotEmpty) {
    return DebugHttpLlmRuntime(endpoint: Uri.parse(debugRuntimeUrl));
  }

  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return IosLlmRuntime();
  }

  throw UnsupportedError('LlmRuntime is not implemented for this platform yet.');
});

final healthDataApiProvider = Provider<IosHealthDataApi>((Ref ref) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return IosHealthDataApi();
  }

  throw UnsupportedError(
    'HealthDataApi is not implemented for this platform yet.',
  );
});

final cryptoApiProvider = Provider<IosCryptoApi>((Ref ref) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return IosCryptoApi();
  }

  throw UnsupportedError('CryptoApi is not implemented for this platform yet.');
});

final backgroundTaskApiProvider = Provider<IosBackgroundTaskApi>((Ref ref) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return IosBackgroundTaskApi();
  }

  throw UnsupportedError(
    'BackgroundTaskApi is not implemented for this platform yet.',
  );
});
