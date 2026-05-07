import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/ai/demo_chat_controller.dart';
import 'package:gemma_local/application/ai/generation_budget_policy.dart';
import 'package:gemma_local/application/ai/model/device_capabilities_reader.dart';
import 'package:gemma_local/application/ai/model/model_artifact_preparer.dart';
import 'package:gemma_local/application/ai/model/model_catalog.dart';
import 'package:gemma_local/application/ai/model/model_file_downloader.dart';
import 'package:gemma_local/application/ai/model/model_lifecycle_service.dart';
import 'package:gemma_local/application/ai/model/model_registry_store.dart';
import 'package:gemma_local/application/ai/model/model_selection_service.dart';
import 'package:gemma_local/application/ai/model/model_storage_paths.dart';
import 'package:gemma_local/core/native/device_capabilities_channel_reader.dart';
import 'package:gemma_local/core/native/generated/device_capabilities_api.g.dart'
    as pigeon;
import 'package:gemma_local/data/model/asset_model_catalog.dart';
import 'package:gemma_local/data/model/dart_model_file_verifier.dart';
import 'package:gemma_local/data/model/hugging_face_model_repository.dart';
import 'package:gemma_local/data/model/json_model_registry_store.dart';
import 'package:gemma_local/data/model/model_artifact_preparers.dart';
import 'package:gemma_local/domain/ai/device_capabilities.dart';
import 'package:gemma_local/domain/ai/llm_generation_config.dart';
import 'package:gemma_local/domain/ai/llm_model_config.dart';
import 'package:gemma_local/domain/ai/llm_response.dart';
import 'package:gemma_local/domain/ai/llm_runtime.dart';
import 'package:gemma_local/domain/ai/llm_runtime_status.dart';
import 'package:gemma_local/domain/ai/llm_token_event.dart';
import 'package:gemma_local/domain/ai/model_install_record.dart';
import 'package:gemma_local/domain/ai/model_install_status.dart';
import 'package:gemma_local/domain/ai/model_manifest.dart';
import 'package:gemma_local/domain/ai/model_manifest_entry.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'asset manifest parses CoreML bundle and LiteRT-LM file artifacts',
    () async {
      final manifest = await const AssetModelCatalog().load();

      expect(manifest.schemaVersion, '1.0');
      final iosModel = manifest.byId('gemma-4-e2b-it-coreml-ios');
      final androidModel = manifest.byId('gemma-4-e4b-it-litert-android');

      expect(iosModel.runtime, 'coreml_llm');
      expect(iosModel.artifactType, 'coreml_bundle');
      expect(iosModel.repoId, 'mlboydaisuke/gemma-4-E2B-coreml');
      expect(iosModel.supportsPlatform('ios'), isTrue);
      expect(androidModel.runtime, 'litert_lm');
      expect(androidModel.artifactType, 'litertlm_file');
      expect(androidModel.fileName, 'gemma-4-E4B-it.litertlm');
      expect(androidModel.supportsPlatform('android'), isTrue);
    },
  );

  test('selection picks CoreML E2B by default on iOS', () async {
    final manifest = await const AssetModelCatalog().load();
    const selection = ModelSelectionService();

    final selectedModel = selection.select(
      manifest: manifest,
      capabilities: const DeviceCapabilities(
        platform: 'ios',
        totalMemoryGb: 16,
        freeDiskBytes: 9000000000,
      ),
    );

    expect(selectedModel.id, 'gemma-4-e2b-it-coreml-ios');
    expect(selectedModel.runtime, 'coreml_llm');
  });

  test(
    'selection can pick CoreML E4B on iOS when explicitly requested',
    () async {
      final manifest = await const AssetModelCatalog().load();
      const selection = ModelSelectionService();

      final selectedModel = selection.select(
        manifest: manifest,
        capabilities: const DeviceCapabilities(
          platform: 'ios',
          totalMemoryGb: 16,
          freeDiskBytes: 9000000000,
        ),
        preferredModelId: 'gemma-4-e4b-it-coreml-ios',
      );

      expect(selectedModel.id, 'gemma-4-e4b-it-coreml-ios');
    },
  );

  test('selection keeps Android on LiteRT-LM entries', () async {
    final manifest = await const AssetModelCatalog().load();
    const selection = ModelSelectionService();

    final highMemoryModel = selection.select(
      manifest: manifest,
      capabilities: const DeviceCapabilities(
        platform: 'android',
        totalMemoryGb: 16,
        freeDiskBytes: 9000000000,
      ),
    );
    final lowMemoryModel = selection.select(
      manifest: manifest,
      capabilities: const DeviceCapabilities(
        platform: 'android',
        totalMemoryGb: 8,
        freeDiskBytes: 9000000000,
      ),
    );

    expect(highMemoryModel.id, 'gemma-4-e4b-it-litert-android');
    expect(lowMemoryModel.id, 'gemma-4-e2b-it-litert-android');
    expect(highMemoryModel.runtime, 'litert_lm');
  });

  test('selection excludes models for incompatible platforms', () async {
    final manifest = await const AssetModelCatalog().load();
    const selection = ModelSelectionService();

    final selectedModel = selection.select(
      manifest: manifest,
      capabilities: const DeviceCapabilities(
        platform: 'android',
        totalMemoryGb: 16,
        freeDiskBytes: 9000000000,
      ),
      preferredModelId: 'gemma-4-e2b-it-coreml-ios',
    );

    expect(selectedModel.supportsPlatform('android'), isTrue);
    expect(selectedModel.runtime, 'litert_lm');
  });

  test('device capabilities reader maps Pigeon payload', () async {
    final reader = DeviceCapabilitiesChannelReader(
      api: _FakeDeviceCapabilitiesHostApi(),
    );

    final capabilities = await reader.read();

    expect(capabilities.platform, 'ios');
    expect(capabilities.totalMemoryGb, 16);
    expect(capabilities.freeDiskBytes, 123456789);
    expect(capabilities.supportsGpu, isFalse);
    expect(capabilities.supportsNpu, isFalse);
    expect(capabilities.deviceModel, 'iPhone18,1');
  });

  test('Dart verifier checks SHA-256', () async {
    final tempDir = await Directory.systemTemp.createTemp('model_verifier_');
    addTearDown(() async => tempDir.delete(recursive: true));
    final file = File(p.join(tempDir.path, 'sample.bin'));
    await file.writeAsString('ready');

    final expectedHash = sha256.convert(utf8.encode('ready')).toString();
    final verifier = const DartModelFileVerifier();

    expect(
      await verifier.verifySha256(
        path: file.path,
        expectedSha256: expectedHash,
      ),
      isTrue,
    );
  });

  test('JSON registry store persists model install records', () async {
    final tempDir = await Directory.systemTemp.createTemp('model_registry_');
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = JsonModelRegistryStore(
      registryPath: p.join(tempDir.path, 'model_registry.json'),
    );
    final now = DateTime.utc(2026, 4, 27);
    final record = ModelInstallRecord(
      modelId: 'gemma-4-e2b-it',
      displayName: 'Gemma 4 E2B',
      localPath: '/models/gemma-4-E2B-it.litertlm',
      sha256: 'TO_BE_FILLED',
      sizeBytes: 1,
      sourceCommit: 'commit',
      runtime: 'litert_lm',
      artifactType: 'litertlm_file',
      revision: 'commit',
      status: ModelInstallStatus.installed,
      createdAt: now,
      updatedAt: now,
    );

    await store.upsert(record);

    final persisted = await store.read('gemma-4-e2b-it');
    expect(persisted?.status, ModelInstallStatus.installed);
    expect(persisted?.runtime, 'litert_lm');
    expect(persisted?.artifactType, 'litertlm_file');
    expect(persisted?.revision, 'commit');
  });

  test(
    'lifecycle downloads, registers, initializes, and smoke tests',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('model_lifecycle_');
      addTearDown(() async => tempDir.delete(recursive: true));
      final model = _testModel();
      final registry = _MemoryRegistryStore();
      final runtime = _FakeLlmRuntime();
      final service = ModelLifecycleService(
        catalog: _FakeCatalog(
          ModelManifest(schemaVersion: '1.0', models: [model]),
        ),
        deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
        selectionService: const ModelSelectionService(),
        storagePaths: _FakeStoragePaths(p.join(tempDir.path, model.fileName)),
        artifactPreparer: const FileModelArtifactPreparer(
          downloader: _FakeDownloader(),
          verifier: DartModelFileVerifier(),
        ),
        registryStore: registry,
        runtime: runtime,
      );

      final progress = await service.prepareDemoModel().toList();

      expect(
        progress.map((item) => item.status),
        containsAllInOrder([
          ModelInstallStatus.downloading,
          ModelInstallStatus.verifying,
          ModelInstallStatus.installed,
          ModelInstallStatus.loading,
          ModelInstallStatus.ready,
        ]),
      );
      expect(runtime.initializedModelId, model.id);
      expect(runtime.initializedConfig?.runtime, 'litert_lm');
      expect(runtime.initializedConfig?.artifactType, 'litertlm_file');
      expect(runtime.initializedConfig?.revision, 'commit');
      expect((await registry.read(model.id))?.status, ModelInstallStatus.ready);
    },
  );

  test(
    'CoreML bundle preparer downloads allowed files and reaches readiness',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('coreml_bundle_');
      addTearDown(() async => tempDir.delete(recursive: true));
      const repository = _FakeHuggingFaceModelRepository(
        files: <String>[
          'README.md',
          'model_config.json',
          'hf_model/config.json',
          'hf_model/tokenizer.json',
          'hf_model/tokenizer_config.json',
          'swa/chunk1.mlmodelc/model.mil',
          'swa/chunk1.mlmodelc/coremldata.bin',
          'swa/chunk1.mlmodelc/weights/weight.bin',
          'swa/chunk2_3way.mlmodelc/coremldata.bin',
          'swa/chunk3_3way.mlmodelc/coremldata.bin',
          'embed_tokens_q8.bin',
          'embed_tokens_scales.bin',
          'embed_tokens_per_layer_q8.bin',
          'embed_tokens_per_layer_scales.bin',
          'per_layer_projection.bin',
          'notes.txt',
        ],
      );
      const preparer = CoreMlBundleArtifactPreparer(repository: repository);
      final model = _testCoreMlModel();

      await preparer.prepare(
        model: model,
        targetPath: tempDir.path,
        requiresWiFi: true,
      );

      expect(await File(p.join(tempDir.path, 'README.md')).exists(), isFalse);
      expect(
        await File(p.join(tempDir.path, 'model_config.json')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(tempDir.path, 'hf_model/tokenizer.json')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(tempDir.path, 'chunk1.mlmodelc/model.mil')).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(tempDir.path, 'swa/chunk1.mlmodelc/model.mil'),
        ).exists(),
        isFalse,
      );
      final readiness = await preparer.readiness(
        model: model,
        targetPath: tempDir.path,
      );
      expect(readiness.isReady, isTrue);
    },
  );

  test('CoreML bundle readiness reports missing bundle parts', () async {
    final tempDir = await Directory.systemTemp.createTemp('coreml_missing_');
    addTearDown(() async => tempDir.delete(recursive: true));
    const preparer = CoreMlBundleArtifactPreparer(
      repository: _FakeHuggingFaceModelRepository(),
    );
    final model = _testCoreMlModel();

    var readiness = await preparer.readiness(
      model: model,
      targetPath: tempDir.path,
    );
    expect(readiness.isReady, isFalse);
    expect(readiness.message, contains('model_config.json'));

    await File(p.join(tempDir.path, 'model_config.json')).writeAsString('{}');
    readiness = await preparer.readiness(
      model: model,
      targetPath: tempDir.path,
    );
    expect(readiness.isReady, isFalse);
    expect(readiness.message, contains('hf_model'));

    final hfModelDir = Directory(p.join(tempDir.path, 'hf_model'));
    await hfModelDir.create();
    await File(p.join(hfModelDir.path, 'config.json')).writeAsString('{}');
    await File(p.join(hfModelDir.path, 'tokenizer.json')).writeAsString('{}');
    await File(
      p.join(hfModelDir.path, 'tokenizer_config.json'),
    ).writeAsString('{}');
    readiness = await preparer.readiness(
      model: model,
      targetPath: tempDir.path,
    );
    expect(readiness.isReady, isFalse);
    expect(readiness.message, contains('.mlmodelc'));
  });

  test(
    'lifecycle uses artifact preparer for CoreML bundle before runtime',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'coreml_lifecycle_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final model = _testCoreMlModel();
      final preparer = _RecordingArtifactPreparer();
      final registry = _MemoryRegistryStore();
      final runtime = _FakeLlmRuntime();
      final service = ModelLifecycleService(
        catalog: _FakeCatalog(
          ModelManifest(schemaVersion: '1.0', models: [model]),
        ),
        deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
        selectionService: const ModelSelectionService(),
        storagePaths: _FakeStoragePaths(tempDir.path),
        artifactPreparer: preparer,
        registryStore: registry,
        runtime: runtime,
      );

      final progress = await service.prepareDemoModel().toList();

      expect(preparer.prepareCalls, 1);
      expect(
        progress.map((item) => item.status),
        containsAllInOrder([
          ModelInstallStatus.downloading,
          ModelInstallStatus.verifying,
          ModelInstallStatus.installed,
          ModelInstallStatus.loading,
          ModelInstallStatus.ready,
        ]),
      );
      expect(runtime.initializedModelId, model.id);
      final record = await registry.read(model.id);
      expect(record?.localPath, tempDir.path);
      expect(record?.runtime, 'coreml_llm');
      expect(record?.artifactType, 'coreml_bundle');
      expect(record?.status, ModelInstallStatus.ready);
    },
  );

  test(
    'generation budget adapts by intent within manifest and context caps',
    () {
      const policy = GenerationBudgetPolicy();
      final model = _testCoreMlModel();

      final shortBudget = policy.buildBudget(
        model: model,
        prompt: 'Hi',
        intent: GenerationIntent.shortChat,
      );
      final chatBudget = policy.buildBudget(
        model: model,
        prompt: 'Give me one practical wellbeing suggestion for today.',
        intent: GenerationIntent.chat,
      );
      final detailedBudget = policy.buildBudget(
        model: model,
        prompt: 'Explain a simple afternoon focus routine in detail.',
        intent: GenerationIntent.detailed,
      );
      final reportBudget = policy.buildBudget(
        model: model,
        prompt: 'Write a weekly wellbeing report.',
        intent: GenerationIntent.report,
      );

      expect(shortBudget.maxTokens, inInclusiveRange(256, 512));
      expect(chatBudget.maxTokens, inInclusiveRange(512, 1024));
      expect(detailedBudget.maxTokens, inInclusiveRange(1024, 2048));
      expect(reportBudget.maxTokens, inInclusiveRange(2048, 4000));
      expect(reportBudget.maxTokens, lessThanOrEqualTo(4000));
      expect(
        reportBudget.maxTokens + reportBudget.estimatedInputTokens,
        lessThanOrEqualTo(model.maxContextTokens),
      );
    },
  );

  test('generation budget rejects insufficient remaining context', () {
    const policy = GenerationBudgetPolicy();
    final model = _testCoreMlModel(maxContextTokens: 200);

    expect(
      () => policy.buildBudget(
        model: model,
        prompt: 'x' * 300,
        intent: GenerationIntent.chat,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('demo chat uses dynamic generation budget from manifest', () async {
    final model = _testCoreMlModel();
    final runtime = _FakeLlmRuntime()..initializedModelId = model.id;
    final controller = _testDemoChatController(model: model, runtime: runtime);

    final response = await controller.ask(prompt: 'What is 2+2?');

    expect(response.text, 'The answer is 4.');
    expect(runtime.generatedPrompts, <String>['What is 2+2?']);
    expect(runtime.generatedConfigs.single.maxTokens, isNot(32));
    expect(
      runtime.generatedConfigs.single.maxTokens,
      inInclusiveRange(512, 1024),
    );
    expect(
      runtime.generatedConfigs.single.topK,
      model.defaultGenerationConfig.topK,
    );
    expect(runtime.generatedConfigs.single.temperature, 1);
  });

  test('demo chat report intent uses a larger dynamic budget', () async {
    final model = _testCoreMlModel();
    final runtime = _FakeLlmRuntime()..initializedModelId = model.id;
    final controller = _testDemoChatController(model: model, runtime: runtime);

    await controller.ask(
      prompt: 'Summarize today.',
      intent: GenerationIntent.chat,
    );
    await controller.ask(
      prompt: 'Write a weekly wellbeing report.',
      intent: GenerationIntent.report,
    );

    expect(
      runtime.generatedConfigs.last.maxTokens,
      greaterThan(runtime.generatedConfigs.first.maxTokens),
    );
    expect(runtime.generatedConfigs.last.maxTokens, lessThanOrEqualTo(4000));
  });

  test('demo chat continues once when output looks truncated', () async {
    final model = _testCoreMlModel();
    final runtime = _FakeLlmRuntime()
      ..initializedModelId = model.id
      ..responseTexts.addAll(<String>[
        List<String>.filled(430, 'focus').join(' '),
        'and finish with a complete sentence.',
      ]);
    final controller = _testDemoChatController(model: model, runtime: runtime);

    final response = await controller.ask(
      prompt: 'Give me a practical focus suggestion.',
    );

    expect(runtime.generatedPrompts, hasLength(2));
    expect(
      runtime.generatedPrompts.last,
      startsWith(DemoChatController.continuationPromptPrefix),
    );
    expect(response.text, contains('and finish with a complete sentence.'));
  });
}

DemoChatController _testDemoChatController({
  required ModelManifestEntry model,
  required _FakeLlmRuntime runtime,
}) {
  return DemoChatController(
    catalog: _FakeCatalog(ModelManifest(schemaVersion: '1.0', models: [model])),
    deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
    selectionService: const ModelSelectionService(),
    lifecycleService: ModelLifecycleService(
      catalog: _FakeCatalog(
        ModelManifest(schemaVersion: '1.0', models: [model]),
      ),
      deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
      selectionService: const ModelSelectionService(),
      storagePaths: const _FakeStoragePaths('/tmp/gemma4-e2b'),
      artifactPreparer: _RecordingArtifactPreparer(),
      registryStore: _MemoryRegistryStore(),
      runtime: runtime,
    ),
    runtime: runtime,
  );
}

ModelManifestEntry _testModel() {
  return const ModelManifestEntry(
    id: 'gemma-4-e2b-it',
    displayName: 'Gemma 4 E2B',
    provider: 'litert-community',
    modelId: 'litert-community/gemma-4-E2B-it-litert-lm',
    runtime: 'litert_lm',
    artifactType: 'litertlm_file',
    revision: 'commit',
    fileName: 'gemma-4-E2B-it.litertlm',
    downloadUrl: 'https://example.test/model.litertlm',
    sourceCommit: 'commit',
    sha256: 'TO_BE_FILLED',
    sizeBytes: 5,
    minMemoryGb: 8,
    minFreeDiskBytes: 10,
    modalities: <String>['text', 'image', 'audio'],
    supportsThinking: true,
    maxContextTokens: 32000,
    defaultGenerationConfig: LlmGenerationConfig(
      topK: 64,
      topP: 0.95,
      temperature: 1,
      maxTokens: 4000,
      enableThinking: true,
    ),
    accelerators: <String>['gpu', 'cpu'],
    isDefault: true,
    platforms: <String>['ios', 'android'],
    selectionPriority: 10,
  );
}

ModelManifestEntry _testCoreMlModel({
  int maxContextTokens = 32000,
  int maxOutputTokens = 4000,
}) {
  return ModelManifestEntry(
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
    maxContextTokens: maxContextTokens,
    defaultGenerationConfig: LlmGenerationConfig(
      topK: 64,
      topP: 0.95,
      temperature: 1,
      maxTokens: maxOutputTokens,
      enableThinking: true,
    ),
    accelerators: <String>['ane', 'gpu', 'cpu'],
    isDefault: true,
    platforms: <String>['ios'],
    selectionPriority: 10,
    repoId: 'mlboydaisuke/gemma-4-E2B-coreml',
    allowPatterns: <String>[
      'model_config.json',
      'hf_model/**',
      'swa/chunk1.mlmodelc/**',
      'swa/chunk2_3way.mlmodelc/**',
      'swa/chunk3_3way.mlmodelc/**',
      '*.bin',
      '*.npy',
      '*.txt',
    ],
  );
}

class _FakeCatalog implements ModelCatalog {
  const _FakeCatalog(this.manifest);

  final ModelManifest manifest;

  @override
  Future<ModelManifest> load() async => manifest;
}

class _FakeDeviceCapabilitiesReader implements DeviceCapabilitiesReader {
  const _FakeDeviceCapabilitiesReader();

  @override
  Future<DeviceCapabilities> read() async {
    return const DeviceCapabilities(
      platform: 'ios',
      totalMemoryGb: 16,
      freeDiskBytes: 100,
    );
  }
}

class _FakeDeviceCapabilitiesHostApi extends pigeon.DeviceCapabilitiesHostApi {
  @override
  Future<pigeon.NativeDeviceCapabilities> read() async {
    return pigeon.NativeDeviceCapabilities(
      platform: 'ios',
      totalMemoryGb: 16,
      freeDiskBytes: 123456789,
      supportsGpu: false,
      supportsNpu: false,
      deviceModel: 'iPhone18,1',
    );
  }
}

class _FakeStoragePaths implements ModelStoragePaths {
  const _FakeStoragePaths(this.path);

  final String path;

  @override
  Future<String> modelFilePath(ModelManifestEntry model) async => path;

  @override
  Future<String> registryFilePath() async {
    return p.join(p.dirname(path), 'model_registry.json');
  }
}

class _FakeDownloader implements ModelFileDownloader {
  const _FakeDownloader();

  @override
  Future<String> download({
    required ModelManifestEntry model,
    required String destinationPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    final file = File(destinationPath);
    await file.parent.create(recursive: true);
    await file.writeAsString('ready');
    onProgress?.call(1);
    return destinationPath;
  }
}

class _FakeHuggingFaceModelRepository implements HuggingFaceModelRepository {
  const _FakeHuggingFaceModelRepository({this.files = const <String>[]});

  final List<String> files;

  @override
  Future<void> downloadFile({
    required String repoId,
    required String revision,
    required String remotePath,
    required String destinationPath,
  }) async {
    final file = File(destinationPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(remotePath);
  }

  @override
  Future<List<String>> listFiles({
    required String repoId,
    required String revision,
  }) async {
    return files;
  }
}

class _RecordingArtifactPreparer implements ModelArtifactPreparer {
  var prepareCalls = 0;
  var ready = false;

  @override
  Future<void> prepare({
    required ModelManifestEntry model,
    required String targetPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    prepareCalls += 1;
    ready = true;
    onProgress?.call(1);
  }

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    if (ready) {
      return const ModelArtifactReadiness.ready();
    }
    return const ModelArtifactReadiness.missing('missing CoreML test bundle');
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

class _FakeLlmRuntime implements LlmRuntime {
  String? initializedModelId;
  LlmModelConfig? initializedConfig;
  String responseText = 'The answer is 4.';
  var initializeCalls = 0;
  final List<String> responseTexts = <String>[];
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
    final nextResponse = responseTexts.isEmpty
        ? responseText
        : responseTexts.removeAt(0);
    return LlmResponse(
      text: prompt == ModelLifecycleService.smokeTestPrompt
          ? 'Take a short walk today.'
          : nextResponse,
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
    initializeCalls += 1;
    initializedModelId = config.modelId;
    initializedConfig = config;
  }

  @override
  Future<void> unload() async {
    initializedModelId = null;
  }
}
