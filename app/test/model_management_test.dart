import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/ai/demo_chat_controller.dart';
import 'package:gemma_local/application/ai/generation_budget_policy.dart';
import 'package:gemma_local/application/ai/model/device_capabilities_reader.dart';
import 'package:gemma_local/application/ai/model/model_artifact_preparer.dart';
import 'package:gemma_local/application/ai/model/model_catalog.dart';
import 'package:gemma_local/application/ai/model/model_connection_controller.dart';
import 'package:gemma_local/application/ai/model/model_lifecycle_service.dart';
import 'package:gemma_local/application/ai/model/model_registry_store.dart';
import 'package:gemma_local/application/ai/model/model_selection_service.dart';
import 'package:gemma_local/application/ai/model/model_storage_paths.dart';
import 'package:gemma_local/core/native/device_capabilities_channel_reader.dart';
import 'package:gemma_local/core/native/generated/device_capabilities_api.g.dart'
    as pigeon;
import 'package:gemma_local/data/model/application_support_model_storage_paths.dart';
import 'package:gemma_local/data/model/asset_model_catalog.dart';
import 'package:gemma_local/data/model/dart_model_file_verifier.dart';
import 'package:gemma_local/data/model/json_model_registry_store.dart';
import 'package:gemma_local/data/model/model_artifact_preparers.dart';
import 'package:gemma_local/domain/ai/device_capabilities.dart';
import 'package:gemma_local/domain/ai/llm_generation_config.dart';
import 'package:gemma_local/domain/ai/llm_model_config.dart';
import 'package:gemma_local/domain/ai/llm_response.dart';
import 'package:gemma_local/domain/ai/llm_runtime.dart';
import 'package:gemma_local/domain/ai/llm_runtime_status.dart';
import 'package:gemma_local/domain/ai/llm_token_event.dart';
import 'package:gemma_local/domain/ai/model_failure_reason.dart';
import 'package:gemma_local/domain/ai/model_install_progress.dart';
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
    'selection does not reject an already-installed model for low disk',
    () async {
      final manifest = await const AssetModelCatalog().load();
      const selection = ModelSelectionService();

      final selectedModel = selection.select(
        manifest: manifest,
        capabilities: const DeviceCapabilities(
          platform: 'ios',
          totalMemoryGb: 16,
          freeDiskBytes: 0,
        ),
      );

      expect(selectedModel.id, 'gemma-4-e2b-it-coreml-ios');
    },
  );

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

  test('JSON registry maps unknown failure reasons to unknown', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'model_registry_legacy_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final registryPath = p.join(tempDir.path, 'model_registry.json');
    await File(registryPath).writeAsString(
      jsonEncode(<String, Object?>{
        'schema_version': '1.0',
        'records': <Object?>[
          <String, Object?>{
            'model_id': 'gemma-4-e2b-it',
            'display_name': 'Gemma 4 E2B',
            'local_path': '/models/gemma-4-e2b-it',
            'sha256': 'BUNDLE_READINESS_CHECK',
            'size_bytes': 1,
            'source_commit': 'commit',
            'runtime': 'coreml_llm',
            'artifact_type': 'coreml_bundle',
            'revision': 'n1024',
            'status': 'failed',
            'created_at': '2026-04-27T00:00:00.000Z',
            'updated_at': '2026-04-27T00:00:00.000Z',
            'failure_reason': 'legacySmokeFailure',
            'error_message': 'legacy smoke failure',
          },
        ],
      }),
    );

    final store = JsonModelRegistryStore(registryPath: registryPath);
    final persisted = await store.read('gemma-4-e2b-it');

    expect(persisted?.failureReason, ModelFailureReason.unknown);
    expect(persisted?.errorMessage, 'legacy smoke failure');
  });

  test('app support path resolver uses model id and revision', () async {
    final tempDir = await Directory.systemTemp.createTemp('fixed_model_path_');
    addTearDown(() async => tempDir.delete(recursive: true));
    final paths = ApplicationSupportModelStoragePaths(
      rootDirectoryProvider: () async => tempDir,
    );

    final path = await paths.modelFilePath(_testModel());

    expect(path, p.join(tempDir.path, 'models', 'gemma-4-e2b-it', 'commit'));
    expect(await Directory(path).exists(), isTrue);
    expect(
      await paths.registryFilePath(),
      p.join(tempDir.path, 'model_registry.json'),
    );
  });

  test(
    'CoreML n1024 readiness accepts only the fixed chunked bundle',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('n1024_ready_');
      addTearDown(() async => tempDir.delete(recursive: true));
      await _writeReadyCoreMlBundle(tempDir.path);

      final readiness = await CoreMlN1024BundleReadiness().readiness(
        model: _testCoreMlModel(),
        targetPath: tempDir.path,
      );

      expect(readiness.isReady, isTrue);
    },
  );

  test('CoreML n1024 readiness reports the missing fixed path', () async {
    final tempDir = await Directory.systemTemp.createTemp('n1024_missing_');
    addTearDown(() async => tempDir.delete(recursive: true));
    final targetPath = p.join(tempDir.path, 'models', 'missing');

    final readiness = await CoreMlN1024BundleReadiness().readiness(
      model: _testCoreMlModel(),
      targetPath: targetPath,
    );

    expect(readiness.isReady, isFalse);
    expect(readiness.message, contains('Local Gemma model is missing at'));
    expect(readiness.message, contains(targetPath));
  });

  test(
    'CoreML n1024 readiness rejects monolithic CoreML fallback layouts',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'n1024_monolithic_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      for (final path in <String>[
        'model_config.json',
        'hf_model/config.json',
        'hf_model/tokenizer.json',
        'hf_model/tokenizer_config.json',
        'model.mlmodelc/coremldata.bin',
      ]) {
        final file = File(p.join(tempDir.path, path));
        await file.parent.create(recursive: true);
        await file.writeAsString(path);
      }

      final readiness = await CoreMlN1024BundleReadiness().readiness(
        model: _testCoreMlModel(),
        targetPath: tempDir.path,
      );

      expect(readiness.isReady, isFalse);
      expect(readiness.message, contains('embed_tokens_q8.bin'));
    },
  );

  test('CoreML readiness accepts E4B four chunk bundle layout', () async {
    final tempDir = await Directory.systemTemp.createTemp('e4b_ready_');
    addTearDown(() async => tempDir.delete(recursive: true));
    await _writeReadyCoreMlBundle(
      tempDir.path,
      chunkPaths: const <String>[
        'chunk1.mlmodelc/coremldata.bin',
        'chunk2.mlmodelc/coremldata.bin',
        'chunk3.mlmodelc/coremldata.bin',
        'chunk4.mlmodelc/coremldata.bin',
      ],
    );

    final readiness = await CoreMlN1024BundleReadiness().readiness(
      model: _testCoreMlModel(id: 'gemma-4-e4b-it-coreml-ios'),
      targetPath: tempDir.path,
    );

    expect(readiness.isReady, isTrue);
  });

  test('lifecycle returns ready when runtime already has the model', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'model_lifecycle_ready_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final model = _testCoreMlModel();
    final preparer = _RecordingArtifactPreparer()..ready = true;
    final registry = _MemoryRegistryStore();
    final runtime = _FakeLlmRuntime()..initializedModelId = model.id;
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

    final progress = await service.ensureDemoModelReady().toList();

    expect(progress.map((item) => item.status), [
      ModelInstallStatus.notInstalled,
      ModelInstallStatus.ready,
    ]);
    expect(runtime.initializeCalls, 0);
    expect(runtime.generatedPrompts, ['Reply with the single word: ready']);
    expect((await registry.read(model.id))?.status, ModelInstallStatus.ready);
  });

  test(
    'lifecycle initializes from the fixed local CoreML bundle without download',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'coreml_lifecycle_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final model = _testCoreMlModel();
      final registry = _MemoryRegistryStore();
      final runtime = _FakeLlmRuntime();
      await _writeReadyCoreMlBundle(tempDir.path);
      final service = ModelLifecycleService(
        catalog: _FakeCatalog(
          ModelManifest(schemaVersion: '1.0', models: [model]),
        ),
        deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
        selectionService: const ModelSelectionService(),
        storagePaths: _FakeStoragePaths(tempDir.path),
        artifactPreparer: CoreMlN1024BundleReadiness(),
        registryStore: registry,
        runtime: runtime,
      );

      final progress = await service.ensureDemoModelReady().toList();

      expect(progress.map((item) => item.status), [
        ModelInstallStatus.notInstalled,
        ModelInstallStatus.installed,
        ModelInstallStatus.loading,
        ModelInstallStatus.ready,
      ]);
      expect(runtime.initializedModelId, model.id);
      expect(runtime.initializedConfig?.localPath, tempDir.path);
      final record = await registry.read(model.id);
      expect(record?.localPath, tempDir.path);
      expect(record?.runtime, 'coreml_llm');
      expect(record?.artifactType, 'coreml_bundle');
      expect(record?.status, ModelInstallStatus.ready);
    },
  );

  test('lifecycle fails when the runtime smoke test is not ready', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'coreml_lifecycle_smoke_failed_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final model = _testCoreMlModel();
    final registry = _MemoryRegistryStore();
    final runtime = _FakeLlmRuntime()..smokeResponseText = 'not ready';
    await _writeReadyCoreMlBundle(tempDir.path);
    final service = ModelLifecycleService(
      catalog: _FakeCatalog(
        ModelManifest(schemaVersion: '1.0', models: [model]),
      ),
      deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
      selectionService: const ModelSelectionService(),
      storagePaths: _FakeStoragePaths(tempDir.path),
      artifactPreparer: CoreMlN1024BundleReadiness(),
      registryStore: registry,
      runtime: runtime,
    );

    final progress = await service.ensureDemoModelReady().toList();

    expect(progress.map((item) => item.status), [
      ModelInstallStatus.notInstalled,
      ModelInstallStatus.installed,
      ModelInstallStatus.loading,
      ModelInstallStatus.failed,
    ]);
    expect(progress.last.failureReason, ModelFailureReason.smokeTestFailed);
    expect(runtime.initializeCalls, 1);
    expect((await registry.read(model.id))?.status, ModelInstallStatus.failed);
  });

  test(
    'lifecycle fails locally when the fixed model directory is incomplete',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'coreml_lifecycle_missing_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final model = _testCoreMlModel();
      final registry = _MemoryRegistryStore();
      final runtime = _FakeLlmRuntime();
      final service = ModelLifecycleService(
        catalog: _FakeCatalog(
          ModelManifest(schemaVersion: '1.0', models: [model]),
        ),
        deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
        selectionService: const ModelSelectionService(),
        storagePaths: _FakeStoragePaths(tempDir.path),
        artifactPreparer: _RecordingArtifactPreparer(),
        registryStore: registry,
        runtime: runtime,
      );

      final progress = await service.ensureDemoModelReady().toList();

      expect(progress.map((item) => item.status), [
        ModelInstallStatus.notInstalled,
        ModelInstallStatus.failed,
      ]);
      expect(progress.last.failureReason, ModelFailureReason.modelNotFound);
      expect(progress.last.message, contains(tempDir.path));
      expect(runtime.initializeCalls, 0);
      expect(
        (await registry.read(model.id))?.status,
        ModelInstallStatus.failed,
      );
    },
  );

  test('lifecycle downloads missing CoreML bundle before loading', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'coreml_lifecycle_download_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final model = _testCoreMlModel();
    final registry = _MemoryRegistryStore();
    final runtime = _FakeLlmRuntime();
    final preparer = _DownloadingArtifactPreparer();
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

    final progress = await service.ensureDemoModelReady().toList();

    expect(progress.map((item) => item.status), [
      ModelInstallStatus.notInstalled,
      ModelInstallStatus.downloading,
      ModelInstallStatus.verifying,
      ModelInstallStatus.installed,
      ModelInstallStatus.loading,
      ModelInstallStatus.ready,
    ]);
    expect(preparer.prepareCalls, 1);
    expect(runtime.initializedModelId, model.id);
    expect((await registry.read(model.id))?.status, ModelInstallStatus.ready);
  });

  test(
    'lifecycle refuses missing CoreML download when disk is too low',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'coreml_lifecycle_low_disk_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final model = _testCoreMlModel(minFreeDiskBytes: 200);
      final registry = _MemoryRegistryStore();
      final runtime = _FakeLlmRuntime();
      final preparer = _DownloadingArtifactPreparer();
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

      final progress = await service.ensureDemoModelReady().toList();

      expect(progress.map((item) => item.status), [
        ModelInstallStatus.notInstalled,
        ModelInstallStatus.failed,
      ]);
      expect(progress.last.failureReason, ModelFailureReason.insufficientDisk);
      expect(preparer.prepareCalls, 0);
      expect(runtime.initializeCalls, 0);
    },
  );

  test(
    'lifecycle ignores stale registry paths and uses resolved fixed path',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'coreml_lifecycle_stale_registry_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final model = _testCoreMlModel();
      final registry = _MemoryRegistryStore();
      final now = DateTime.utc(2026, 5, 10);
      await registry.upsert(
        ModelInstallRecord(
          modelId: model.id,
          displayName: model.displayName,
          localPath: '/stale/model/path',
          sha256: model.sha256,
          sizeBytes: model.sizeBytes,
          sourceCommit: model.sourceCommit,
          runtime: model.runtime,
          artifactType: model.artifactType,
          revision: model.revision,
          status: ModelInstallStatus.ready,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final runtime = _FakeLlmRuntime();
      await _writeReadyCoreMlBundle(tempDir.path);
      final service = ModelLifecycleService(
        catalog: _FakeCatalog(
          ModelManifest(schemaVersion: '1.0', models: [model]),
        ),
        deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
        selectionService: const ModelSelectionService(),
        storagePaths: _FakeStoragePaths(tempDir.path),
        artifactPreparer: CoreMlN1024BundleReadiness(),
        registryStore: registry,
        runtime: runtime,
      );

      await service.ensureDemoModelReady().toList();

      expect(runtime.initializedConfig?.localPath, tempDir.path);
      expect((await registry.read(model.id))?.localPath, tempDir.path);
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

      expect(shortBudget.maxTokens, inInclusiveRange(8, 16));
      expect(chatBudget.maxTokens, greaterThan(16));
      expect(detailedBudget.maxTokens, greaterThan(16));
      expect(reportBudget.maxTokens, greaterThan(16));
      expect(
        chatBudget.maxTokens + chatBudget.estimatedInputTokens,
        lessThanOrEqualTo(model.maxContextTokens),
      );
      expect(
        detailedBudget.maxTokens + detailedBudget.estimatedInputTokens,
        lessThanOrEqualTo(model.maxContextTokens),
      );
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
    expect(runtime.generatedPrompts.single, 'What is 2+2?');
    expect(runtime.generatedConfigs.single.maxTokens, isNot(32));
    expect(runtime.generatedConfigs.single.maxTokens, greaterThan(16));
    expect(
      runtime.generatedConfigs.single.topK,
      model.defaultGenerationConfig.topK,
    );
    expect(runtime.generatedConfigs.single.temperature, 1);
  });

  test(
    'demo chat retries with raw user prompt when model returns only pads',
    () async {
      final model = _testCoreMlModel();
      final runtime = _FakeLlmRuntime()
        ..initializedModelId = model.id
        ..responseTexts.addAll(<String>['<pad><pad>', 'Take a short walk.']);
      final controller = _testDemoChatController(
        model: model,
        runtime: runtime,
      );

      final response = await controller.ask(prompt: 'Give me one tip.');

      expect(response.text, 'Take a short walk.');
      expect(runtime.generatedPrompts.first, 'Give me one tip.');
      expect(runtime.generatedPrompts.last, 'Give me one tip.');
      expect(runtime.generatedConfigs.last.maxTokens, greaterThan(16));
      expect(runtime.generatedConfigs.last.enableThinking, isTrue);
    },
  );

  test('short chat does not issue continuation requests', () async {
    final model = _testCoreMlModel();
    final runtime = _FakeLlmRuntime()
      ..initializedModelId = model.id
      ..responseText = List<String>.filled(40, 'focus').join(' ');
    final controller = _testDemoChatController(model: model, runtime: runtime);

    await controller.ask(
      prompt: 'Give me one tip.',
      intent: GenerationIntent.shortChat,
    );

    expect(runtime.generatedPrompts, hasLength(1));
    expect(runtime.generatedConfigs.single.enableThinking, isFalse);
  });

  test(
    'short chat retries and exposes failure when runtime yields no text',
    () async {
      final model = _testCoreMlModel();
      final runtime = _FakeLlmRuntime()
        ..initializedModelId = model.id
        ..responseText = '<pad><pad>';
      final controller = _testDemoChatController(
        model: model,
        runtime: runtime,
      );

      await expectLater(
        controller.ask(
          prompt: 'What is the capital of France?',
          intent: GenerationIntent.shortChat,
        ),
        throwsA(isA<StateError>()),
      );

      expect(runtime.generatedPrompts, hasLength(2));
      expect(
        runtime.generatedPrompts,
        everyElement('What is the capital of France?'),
      );
    },
  );

  test('demo chat report intent stays within context budget', () async {
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

    expect(runtime.generatedConfigs.last.maxTokens, greaterThan(16));
    expect(
      runtime.generatedConfigs.last.maxTokens +
          const GenerationBudgetPolicy().estimateTokens(
            runtime.generatedPrompts.last,
          ),
      lessThanOrEqualTo(model.maxContextTokens),
    );
  });

  test('demo chat continues once when output looks truncated', () async {
    final model = _testCoreMlModel(maxContextTokens: 900);
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

  test('model connection timeout exposes retry state', () async {
    final controller = ModelConnectionController(
      loadController: () => Completer<DemoChatController>().future,
      connectionTimeout: const Duration(milliseconds: 50),
    );

    await controller.ensureModelReady();

    expect(controller.snapshot.status, ModelInstallStatus.failed);
    expect(controller.snapshot.message, contains('timed out'));
  });

  test('model connection retry starts fresh after timeout', () async {
    final model = _testCoreMlModel();
    final runtime = _FakeLlmRuntime()..initializedModelId = model.id;
    var loadCalls = 0;
    final controller = ModelConnectionController(
      loadController: () {
        loadCalls += 1;
        if (loadCalls == 1) {
          return Completer<DemoChatController>().future;
        }
        return Future<DemoChatController>.value(
          _testDemoChatController(model: model, runtime: runtime),
        );
      },
      connectionTimeout: const Duration(milliseconds: 50),
    );

    await controller.ensureModelReady();
    await controller.retry();

    expect(loadCalls, 2);
    expect(controller.snapshot.status, ModelInstallStatus.ready);
  });

  test('model connection cancels active stream after timeout', () async {
    final model = _testCoreMlModel();
    final runtime = _FakeLlmRuntime()..initializedModelId = model.id;
    var staleStreamCanceled = false;
    final staleProgress = StreamController<ModelInstallProgress>(
      onCancel: () {
        staleStreamCanceled = true;
      },
    );
    var loadCalls = 0;
    final controller = ModelConnectionController(
      loadController: () {
        loadCalls += 1;
        if (loadCalls == 1) {
          return Future<DemoChatController>.value(
            _StreamingDemoChatController(staleProgress.stream),
          );
        }
        return Future<DemoChatController>.value(
          _testDemoChatController(model: model, runtime: runtime),
        );
      },
      connectionTimeout: const Duration(milliseconds: 50),
    );

    await controller.ensureModelReady();

    expect(staleStreamCanceled, isTrue);
    expect(controller.snapshot.status, ModelInstallStatus.failed);

    staleProgress.add(
      const ModelInstallProgress(
        modelId: 'gemma-4-e2b-it-coreml-ios',
        status: ModelInstallStatus.ready,
        message: 'stale ready',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot.status, ModelInstallStatus.failed);

    await controller.retry();

    expect(loadCalls, 2);
    expect(controller.snapshot.status, ModelInstallStatus.ready);
    await staleProgress.close();
  });

  test(
    'model connection ignores late controller from timed out attempt',
    () async {
      final model = _testCoreMlModel();
      final runtime = _FakeLlmRuntime()..initializedModelId = model.id;
      final firstCompleter = Completer<DemoChatController>();
      var staleEnsureCalls = 0;
      var loadCalls = 0;
      final controller = ModelConnectionController(
        loadController: () {
          loadCalls += 1;
          if (loadCalls == 1) {
            return firstCompleter.future;
          }
          return Future<DemoChatController>.value(
            _testDemoChatController(model: model, runtime: runtime),
          );
        },
        connectionTimeout: const Duration(milliseconds: 50),
      );

      await controller.ensureModelReady();
      await controller.retry();
      firstCompleter.complete(
        _ScriptedDemoChatController(
          onEnsureModelReady: () {
            staleEnsureCalls += 1;
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(loadCalls, 2);
      expect(staleEnsureCalls, 0);
      expect(controller.snapshot.status, ModelInstallStatus.ready);
    },
  );

  test(
    'model connection lifecycle does not prepare on resume before user request',
    () async {
      var loadCalls = 0;
      final controller = ModelConnectionController(
        loadController: () {
          loadCalls += 1;
          return Future<DemoChatController>.value(
            _ScriptedDemoChatController(),
          );
        },
      );

      await controller.handleLifecycleState(AppLifecycleState.resumed);

      expect(loadCalls, 0);
      expect(controller.snapshot.status, ModelInstallStatus.notInstalled);
    },
  );

  test(
    'model connection lifecycle only cancels on background states',
    () async {
      final model = _testCoreMlModel();
      final runtime = _FakeLlmRuntime()..initializedModelId = model.id;
      final chatController = _testDemoChatController(
        model: model,
        runtime: runtime,
      );
      final controller = ModelConnectionController(
        loadController: () async => chatController,
      );
      await controller.ensureModelReady();

      await controller.handleLifecycleState(AppLifecycleState.inactive);
      await controller.handleLifecycleState(AppLifecycleState.hidden);
      expect(runtime.cancelCalls, 0);

      await controller.handleLifecycleState(AppLifecycleState.paused);
      await controller.handleLifecycleState(AppLifecycleState.detached);
      expect(runtime.cancelCalls, 2);
    },
  );
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
      artifactPreparer: _RecordingArtifactPreparer()..ready = true,
      registryStore: _MemoryRegistryStore(),
      runtime: runtime,
    ),
    runtime: runtime,
  );
}

class _ScriptedDemoChatController extends DemoChatController {
  _ScriptedDemoChatController({this.onEnsureModelReady})
    : super(
        catalog: _FakeCatalog(
          ModelManifest(
            schemaVersion: '1.0',
            models: <ModelManifestEntry>[_scriptedModel],
          ),
        ),
        deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
        selectionService: const ModelSelectionService(),
        lifecycleService: ModelLifecycleService(
          catalog: _FakeCatalog(
            ModelManifest(
              schemaVersion: '1.0',
              models: <ModelManifestEntry>[_scriptedModel],
            ),
          ),
          deviceCapabilitiesReader: const _FakeDeviceCapabilitiesReader(),
          selectionService: const ModelSelectionService(),
          storagePaths: const _FakeStoragePaths('/tmp/gemma4-e2b'),
          artifactPreparer: _RecordingArtifactPreparer()..ready = true,
          registryStore: _MemoryRegistryStore(),
          runtime: _FakeLlmRuntime()..initializedModelId = _scriptedModel.id,
        ),
        runtime: _FakeLlmRuntime()..initializedModelId = _scriptedModel.id,
      );

  static final ModelManifestEntry _scriptedModel = _testCoreMlModel();

  final VoidCallback? onEnsureModelReady;

  @override
  Stream<ModelInstallProgress> ensureModelReady({
    String preferredModelId = DemoChatController.defaultPreferredModelId,
  }) {
    onEnsureModelReady?.call();
    return const Stream<ModelInstallProgress>.empty();
  }
}

class _StreamingDemoChatController extends _ScriptedDemoChatController {
  _StreamingDemoChatController(this.progressStream);

  final Stream<ModelInstallProgress> progressStream;

  @override
  Stream<ModelInstallProgress> ensureModelReady({
    String preferredModelId = DemoChatController.defaultPreferredModelId,
  }) {
    return progressStream;
  }
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
  String id = 'gemma-4-e2b-it-coreml-ios',
  int maxContextTokens = 2048,
  int maxOutputTokens = 4000,
  int minFreeDiskBytes = 10,
}) {
  return ModelManifestEntry(
    id: id,
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
    minFreeDiskBytes: minFreeDiskBytes,
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
      'hf_model/config.json',
      'hf_model/tokenizer.json',
      'hf_model/tokenizer_config.json',
      'swa/chunk1.mlmodelc/**',
      'swa/chunk2_3way.mlmodelc/**',
      'swa/chunk3_3way.mlmodelc/**',
      'embed_tokens_q8.bin',
      'embed_tokens_scales.bin',
      'embed_tokens_per_layer_q8.bin',
      'embed_tokens_per_layer_scales.bin',
      'per_layer_projection.bin',
      'per_layer_norm_weight.bin',
      'cos_sliding.npy',
      'sin_sliding.npy',
      'cos_full.npy',
      'sin_full.npy',
    ],
  );
}

Future<void> _writeReadyCoreMlBundle(
  String targetPath, {
  List<String> chunkPaths = const <String>[
    'chunk1.mlmodelc/coremldata.bin',
    'chunk2_3way.mlmodelc/coremldata.bin',
    'chunk3_3way.mlmodelc/coremldata.bin',
  ],
}) async {
  for (final path in <String>[
    'model_config.json',
    'hf_model/config.json',
    'hf_model/tokenizer.json',
    'hf_model/tokenizer_config.json',
    ...chunkPaths,
    'embed_tokens_q8.bin',
    'embed_tokens_scales.bin',
    'embed_tokens_per_layer_q8.bin',
    'embed_tokens_per_layer_scales.bin',
    'per_layer_projection.bin',
    'per_layer_norm_weight.bin',
    'cos_sliding.npy',
    'sin_sliding.npy',
    'cos_full.npy',
    'sin_full.npy',
  ]) {
    final file = File(p.join(targetPath, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(path);
  }
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

class _RecordingArtifactPreparer implements ModelArtifactPreparer {
  var ready = false;

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    if (ready) {
      return const ModelArtifactReadiness.ready();
    }
    return ModelArtifactReadiness.missing(
      'Local Gemma model is missing at $targetPath.',
    );
  }
}

class _DownloadingArtifactPreparer implements ModelArtifactInstaller {
  var ready = false;
  var prepareCalls = 0;

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

  @override
  Future<ModelArtifactReadiness> prepare({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    prepareCalls += 1;
    ready = true;
    return const ModelArtifactReadiness.ready();
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
  String smokeResponseText = 'ready';
  var initializeCalls = 0;
  var cancelCalls = 0;
  final List<String> responseTexts = <String>[];
  final List<String> generatedPrompts = <String>[];
  final List<LlmGenerationConfig> generatedConfigs = <LlmGenerationConfig>[];

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
  }

  @override
  Future<LlmResponse> generateOnce({
    required String prompt,
    List<Object> attachments = const <Object>[],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  }) async {
    generatedPrompts.add(prompt);
    generatedConfigs.add(config);
    if (prompt == 'Reply with the single word: ready') {
      return LlmResponse(
        text: smokeResponseText,
        modelId: initializedModelId ?? 'unloaded',
      );
    }
    final nextResponse = responseTexts.isEmpty
        ? responseText
        : responseTexts.removeAt(0);
    return LlmResponse(
      text: nextResponse,
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
