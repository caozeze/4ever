import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/app.dart';
import 'package:gemma_local/application/ai/demo_chat_controller.dart';
import 'package:gemma_local/application/ai/model/device_capabilities_reader.dart';
import 'package:gemma_local/application/ai/model/model_artifact_preparer.dart';
import 'package:gemma_local/application/ai/model/model_catalog.dart';
import 'package:gemma_local/application/ai/model/model_file_downloader.dart';
import 'package:gemma_local/application/ai/model/model_lifecycle_service.dart';
import 'package:gemma_local/application/ai/model/model_registry_store.dart';
import 'package:gemma_local/application/ai/model/model_selection_service.dart';
import 'package:gemma_local/application/ai/model/model_storage_paths.dart';
import 'package:gemma_local/application/health/health_authorization_service.dart';
import 'package:gemma_local/core/providers/health_providers.dart';
import 'package:gemma_local/core/providers/model_management_providers.dart';
import 'package:gemma_local/domain/ai/device_capabilities.dart';
import 'package:gemma_local/domain/ai/llm_generation_config.dart';
import 'package:gemma_local/domain/ai/llm_model_config.dart';
import 'package:gemma_local/domain/ai/llm_response.dart';
import 'package:gemma_local/domain/ai/llm_runtime.dart';
import 'package:gemma_local/domain/ai/llm_runtime_status.dart';
import 'package:gemma_local/domain/ai/llm_token_event.dart';
import 'package:gemma_local/domain/ai/model_install_record.dart';
import 'package:gemma_local/domain/ai/model_manifest.dart';
import 'package:gemma_local/domain/ai/model_manifest_entry.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

void main() {
  testWidgets('renders simple in-memory chat shell', (
    WidgetTester tester,
  ) async {
    await _pumpTestApp(tester);

    expect(find.text('Gemma Health Coach'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('gemma_prompt_input')), findsOne);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('Prepare model'), findsNothing);
    expect(find.text('Apple Health'), findsNothing);
  });

  testWidgets('auto prepares Gemma and renders a text answer', (
    WidgetTester tester,
  ) async {
    await _pumpTestApp(tester);

    await tester.tap(find.byKey(const ValueKey<String>('gemma_ask_button')));
    await tester.pumpAndSettle();

    expect(find.text('The answer is 4.'), findsOneWidget);
    expect(find.text('**The answer is 4.**'), findsNothing);
  });

  testWidgets('keeps ask disabled before model is ready', (
    WidgetTester tester,
  ) async {
    final preparer = _FakeArtifactPreparer(completeImmediately: false);
    await _pumpTestApp(tester, artifactPreparer: preparer, settle: false);

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('gemma_ask_button')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Preparing local Gemma 4...'), findsOneWidget);
  });

  testWidgets('opens left menu and navigates to feature placeholders', (
    WidgetTester tester,
  ) async {
    await _pumpTestApp(tester);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Apple Health'), findsOneWidget);
    expect(find.text('Diet'), findsOneWidget);

    await tester.tap(find.text('Sleep'));
    await tester.pumpAndSettle();

    expect(find.text('Sleep'), findsWidgets);
    expect(
      find.text('Planned local-first feature. Not connected yet.'),
      findsOneWidget,
    );
  });

  testWidgets('opens Apple Health page and requests authorization', (
    WidgetTester tester,
  ) async {
    final healthAuthorizationService = _FakeHealthAuthorizationService();
    await _pumpTestApp(
      tester,
      healthAuthorizationService: healthAuthorizationService,
    );

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple Health'));
    await tester.pumpAndSettle();

    expect(find.text('Apple Health Access'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('health_authorize_button')),
      findsOne,
    );
    expect(find.text('Authorize Apple Health Once'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('health_authorize_steps_button')),
      findsNothing,
    );
    expect(find.text('Steps'), findsNothing);
    expect(find.text('Sleep'), findsNothing);
    expect(find.text('Heart Rate'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('health_authorize_button')),
    );
    await tester.pumpAndSettle();

    expect(healthAuthorizationService.requestCount, 1);
    expect(
      find.textContaining('Apple Health request completed once'),
      findsOneWidget,
    );
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.textContaining('Sleep'), findsOne);
    expect(find.textContaining('Heart Rate'), findsOne);
    expect(find.textContaining('Weight'), findsOne);
    expect(find.textContaining('iOS returned no visible data'), findsOne);
  });
}

Future<void> _pumpTestApp(
  WidgetTester tester, {
  _FakeArtifactPreparer? artifactPreparer,
  _FakeHealthAuthorizationService? healthAuthorizationService,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _testApp(
      artifactPreparer: artifactPreparer,
      healthAuthorizationService: healthAuthorizationService,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
}

Widget _testApp({
  _FakeArtifactPreparer? artifactPreparer,
  _FakeHealthAuthorizationService? healthAuthorizationService,
}) {
  return ProviderScope(
    overrides: [
      demoChatControllerProvider.overrideWith((Ref ref) async {
        return _testDemoChatController(artifactPreparer: artifactPreparer);
      }),
      if (healthAuthorizationService != null)
        healthAuthorizationServiceProvider.overrideWithValue(
          healthAuthorizationService,
        ),
    ],
    child: const GemmaLocalApp(),
  );
}

DemoChatController _testDemoChatController({
  _FakeArtifactPreparer? artifactPreparer,
}) {
  final runtime = _FakeLlmRuntime();
  final lifecycle = ModelLifecycleService(
    catalog: const _FakeCatalog(),
    deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
    selectionService: const ModelSelectionService(),
    storagePaths: const _FakeStoragePaths(),
    artifactPreparer: artifactPreparer ?? _FakeArtifactPreparer(),
    registryStore: _MemoryRegistryStore(),
    runtime: runtime,
  );
  return DemoChatController(
    catalog: const _FakeCatalog(),
    deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
    selectionService: const ModelSelectionService(),
    lifecycleService: lifecycle,
    runtime: runtime,
  );
}

class _FakeCatalog implements ModelCatalog {
  const _FakeCatalog();

  @override
  Future<ModelManifest> load() async {
    return const ModelManifest(
      schemaVersion: '1.0',
      models: <ModelManifestEntry>[_testModel],
    );
  }
}

class _FakeDeviceCapabilitiesReader implements DeviceCapabilitiesReader {
  const _FakeDeviceCapabilitiesReader();

  @override
  Future<DeviceCapabilities> read() async {
    return const DeviceCapabilities(
      platform: 'ios',
      totalMemoryGb: 16,
      freeDiskBytes: 9000000000,
      deviceModel: 'iPhone18,1',
    );
  }
}

class _FakeStoragePaths implements ModelStoragePaths {
  const _FakeStoragePaths();

  @override
  Future<String> modelFilePath(ModelManifestEntry model) async {
    return '/tmp/gemma4-e2b';
  }

  @override
  Future<String> registryFilePath() async {
    return '/tmp/model_registry.json';
  }
}

class _FakeArtifactPreparer implements ModelArtifactPreparer {
  _FakeArtifactPreparer({this.completeImmediately = true});

  final bool completeImmediately;
  final Completer<void> _prepareCompleter = Completer<void>();
  var isPrepared = false;

  @override
  Future<void> prepare({
    required ModelManifestEntry model,
    required String targetPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    onProgress?.call(1);
    if (!completeImmediately) {
      await _prepareCompleter.future;
    }
    isPrepared = true;
  }

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    if (isPrepared) {
      return const ModelArtifactReadiness.ready();
    }
    return const ModelArtifactReadiness.missing('missing test bundle');
  }
}

class _MemoryRegistryStore implements ModelRegistryStore {
  final Map<String, ModelInstallRecord> _records =
      <String, ModelInstallRecord>{};

  @override
  Future<List<ModelInstallRecord>> readAll() async {
    return _records.values.toList();
  }

  @override
  Future<ModelInstallRecord?> read(String modelId) async {
    return _records[modelId];
  }

  @override
  Future<void> upsert(ModelInstallRecord record) async {
    _records[record.modelId] = record;
  }
}

final class _FakeHealthAuthorizationService
    implements HealthAuthorizationService {
  int requestCount = 0;
  bool openSettingsCalled = false;

  @override
  Future<HealthAuthorizationResult> requestDefaultReadPermissions() async {
    requestCount += 1;
    return const HealthAuthorizationResult(
      status: HealthAuthorizationService.statusCompleted,
      metrics: <HealthMetricAuthorizationResult>[
        HealthMetricAuthorizationResult(
          metric: HealthMetricType.steps,
          status: HealthAuthorizationService.statusReadable,
          summary: <String, Object?>{
            'value': 1234,
            'unit': 'count',
            'sample_count': 1,
          },
        ),
        HealthMetricAuthorizationResult(
          metric: HealthMetricType.sleepSession,
          status: HealthAuthorizationService.statusNoVisibleData,
        ),
        HealthMetricAuthorizationResult(
          metric: HealthMetricType.heartRate,
          status: HealthAuthorizationService.statusNoVisibleData,
        ),
        HealthMetricAuthorizationResult(
          metric: HealthMetricType.hrv,
          status: HealthAuthorizationService.statusNoVisibleData,
        ),
        HealthMetricAuthorizationResult(
          metric: HealthMetricType.activeEnergy,
          status: HealthAuthorizationService.statusNoVisibleData,
        ),
        HealthMetricAuthorizationResult(
          metric: HealthMetricType.weight,
          status: HealthAuthorizationService.statusNoVisibleData,
        ),
      ],
    );
  }

  @override
  Future<bool> openAppSettings() async {
    openSettingsCalled = true;
    return true;
  }
}

class _FakeLlmRuntime implements LlmRuntime {
  String? _loadedModelId;

  @override
  Future<void> cancel() async {}

  @override
  Future<LlmResponse> generateOnce({
    required String prompt,
    List<Object> attachments = const <Object>[],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  }) async {
    return LlmResponse(
      text: '**The answer is 4.**',
      modelId: _loadedModelId ?? 'unloaded',
    );
  }

  @override
  Stream<LlmTokenEvent> generateStream({
    required String prompt,
    List<Object> attachments = const <Object>[],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  }) {
    return const Stream<LlmTokenEvent>.empty();
  }

  @override
  Future<LlmRuntimeStatus> getStatus() async {
    return LlmRuntimeStatus(
      state: _loadedModelId == null ? 'unloaded' : 'ready',
      loadedModelId: _loadedModelId,
    );
  }

  @override
  Future<void> initialize(LlmModelConfig config) async {
    _loadedModelId = config.modelId;
  }

  @override
  Future<void> unload() async {
    _loadedModelId = null;
  }
}

const _testModel = ModelManifestEntry(
  id: 'gemma-4-e2b-it-coreml-ios',
  displayName: 'Gemma 4 E2B Core ML',
  provider: 'mlboydaisuke',
  modelId: 'mlboydaisuke/gemma-4-E2B-coreml',
  runtime: 'coreml_llm',
  artifactType: 'coreml_bundle',
  revision: 'n1024',
  fileName: '',
  downloadUrl: '',
  sourceCommit: 'n1024',
  sha256: 'BUNDLE_READINESS_CHECK',
  sizeBytes: 2583085056,
  minMemoryGb: 8,
  minFreeDiskBytes: 10,
  modalities: <String>['text'],
  supportsThinking: true,
  maxContextTokens: 2048,
  defaultGenerationConfig: LlmGenerationConfig(
    topK: 64,
    topP: 0.95,
    temperature: 1,
    maxTokens: 4000,
    enableThinking: true,
  ),
  accelerators: <String>['ane', 'gpu', 'cpu'],
  isDefault: true,
  platforms: <String>['ios'],
  selectionPriority: 10,
  repoId: 'mlboydaisuke/gemma-4-E2B-coreml',
  allowPatterns: <String>['*.json', '*.mlmodelc/**', '*.bin', '*.txt'],
);
