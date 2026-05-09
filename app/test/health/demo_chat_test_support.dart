import 'package:gemma_local/application/ai/demo_chat_controller.dart';
import 'package:gemma_local/application/ai/model/device_capabilities_reader.dart';
import 'package:gemma_local/application/ai/model/model_artifact_preparer.dart';
import 'package:gemma_local/application/ai/model/model_catalog.dart';
import 'package:gemma_local/application/ai/model/model_file_downloader.dart';
import 'package:gemma_local/application/ai/model/model_lifecycle_service.dart';
import 'package:gemma_local/application/ai/model/model_registry_store.dart';
import 'package:gemma_local/application/ai/model/model_selection_service.dart';
import 'package:gemma_local/application/ai/model/model_storage_paths.dart';
import 'package:gemma_local/application/health/health_prompt_context_service.dart';
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

DemoChatController testDemoChatController({
  required RecordingLlmRuntime runtime,
  HealthPromptContextService? healthPromptContextService,
}) {
  return DemoChatController(
    catalog: const _FakeCatalog(),
    deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
    selectionService: const ModelSelectionService(),
    lifecycleService: ModelLifecycleService(
      catalog: const _FakeCatalog(),
      deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
      selectionService: const ModelSelectionService(),
      storagePaths: const _FakeStoragePaths(),
      artifactPreparer: _RecordingArtifactPreparer(),
      registryStore: _MemoryRegistryStore(),
      runtime: runtime,
    ),
    runtime: runtime,
    healthPromptContextService: healthPromptContextService,
  );
}

final class RecordingLlmRuntime implements LlmRuntime {
  String? initializedModelId = testCoreMlModel.id;
  String responseText = 'The answer is 4.';
  final List<String> generatedPrompts = <String>[];
  final List<LlmGenerationConfig> generatedConfigs = <LlmGenerationConfig>[];

  @override
  Future<void> cancel() async {}

  @override
  Future<LlmResponse> generateOnce({
    required String prompt,
    List<Object> attachments = const <Object>[],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  }) async {
    generatedPrompts.add(prompt);
    generatedConfigs.add(config);
    return LlmResponse(
      text: responseText,
      modelId: initializedModelId ?? 'unloaded',
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
      state: initializedModelId == null ? 'unloaded' : 'ready',
      loadedModelId: initializedModelId,
    );
  }

  @override
  Future<void> initialize(LlmModelConfig config) async {
    initializedModelId = config.modelId;
  }

  @override
  Future<void> unload() async {
    initializedModelId = null;
  }
}

const testCoreMlModel = ModelManifestEntry(
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
  allowPatterns: <String>['model_config.json', 'hf_model/**'],
);

class _FakeCatalog implements ModelCatalog {
  const _FakeCatalog();

  @override
  Future<ModelManifest> load() async {
    return const ModelManifest(
      schemaVersion: '1.0',
      models: <ModelManifestEntry>[testCoreMlModel],
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

class _RecordingArtifactPreparer implements ModelArtifactPreparer {
  @override
  Future<void> prepare({
    required ModelManifestEntry model,
    required String targetPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    onProgress?.call(1);
  }

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    return const ModelArtifactReadiness.ready();
  }
}

class _MemoryRegistryStore implements ModelRegistryStore {
  final Map<String, ModelInstallRecord> _records =
      <String, ModelInstallRecord>{};

  @override
  Future<List<ModelInstallRecord>> readAll() async {
    return _records.values.toList(growable: false);
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
