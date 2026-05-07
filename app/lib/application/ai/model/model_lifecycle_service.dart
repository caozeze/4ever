import '../../../domain/ai/device_capabilities.dart';
import '../../../domain/ai/llm_generation_config.dart';
import '../../../domain/ai/llm_runtime.dart';
import '../../../domain/ai/model_failure_reason.dart';
import '../../../domain/ai/model_install_progress.dart';
import '../../../domain/ai/model_install_record.dart';
import '../../../domain/ai/model_install_status.dart';
import '../../../domain/ai/model_manifest_entry.dart';
import 'device_capabilities_reader.dart';
import 'model_artifact_preparer.dart';
import 'model_catalog.dart';
import 'model_registry_store.dart';
import 'model_selection_service.dart';
import 'model_storage_paths.dart';

class ModelLifecycleService {
  const ModelLifecycleService({
    required ModelCatalog catalog,
    required DeviceCapabilitiesReader deviceCapabilitiesReader,
    required ModelSelectionService selectionService,
    required ModelStoragePaths storagePaths,
    required ModelArtifactPreparer artifactPreparer,
    required ModelRegistryStore registryStore,
    required LlmRuntime runtime,
  }) : _catalog = catalog,
       _deviceCapabilitiesReader = deviceCapabilitiesReader,
       _selectionService = selectionService,
       _storagePaths = storagePaths,
       _artifactPreparer = artifactPreparer,
       _registryStore = registryStore,
       _runtime = runtime;

  static const String smokeTestPrompt =
      'Give me one short wellbeing suggestion for today.';
  static const LlmGenerationConfig smokeTestGenerationConfig =
      LlmGenerationConfig(maxTokens: 24, enableThinking: false);
  static const Duration smokeTestTimeout = Duration(minutes: 10);
  static const String debugRemoteRuntimeUrl = String.fromEnvironment(
    'GEMMA_MVP_REMOTE_RUNTIME_URL',
  );
  static const String debugRemoteModelPath = String.fromEnvironment(
    'GEMMA_MVP_REMOTE_MODEL_PATH',
  );

  final ModelCatalog _catalog;
  final DeviceCapabilitiesReader _deviceCapabilitiesReader;
  final ModelSelectionService _selectionService;
  final ModelStoragePaths _storagePaths;
  final ModelArtifactPreparer _artifactPreparer;
  final ModelRegistryStore _registryStore;
  final LlmRuntime _runtime;

  Stream<ModelInstallProgress> prepareDemoModel({
    String? preferredModelId,
    bool requiresWiFi = true,
  }) async* {
    final capabilities = await _deviceCapabilitiesReader.read();
    final manifest = await _catalog.load();
    final model = _selectionService.select(
      manifest: manifest,
      capabilities: capabilities,
      preferredModelId: preferredModelId,
    );

    yield* installAndLoad(
      model: model,
      capabilities: capabilities,
      requiresWiFi: requiresWiFi,
    );
  }

  Stream<ModelInstallProgress> installAndLoad({
    required ModelManifestEntry model,
    required DeviceCapabilities capabilities,
    bool requiresWiFi = true,
  }) async* {
    final now = DateTime.now().toUtc();
    final targetPath = debugRemoteModelPath.isNotEmpty
        ? debugRemoteModelPath
        : await _storagePaths.modelFilePath(model);
    var record = ModelInstallRecord(
      modelId: model.id,
      displayName: model.displayName,
      localPath: targetPath,
      sha256: model.sha256,
      sizeBytes: model.sizeBytes,
      sourceCommit: model.sourceCommit,
      runtime: model.runtime,
      artifactType: model.artifactType,
      revision: model.revision,
      status: ModelInstallStatus.notInstalled,
      createdAt: now,
      updatedAt: now,
    );

    if (!model.supportsPlatform(capabilities.platform)) {
      yield _failed(model, ModelFailureReason.unsupportedPlatform);
      return;
    }

    if (capabilities.totalMemoryGb < model.minMemoryGb) {
      yield _failed(model, ModelFailureReason.insufficientMemory);
      return;
    }

    if (capabilities.freeDiskBytes < model.minFreeDiskBytes) {
      yield _failed(model, ModelFailureReason.insufficientDisk);
      return;
    }

    final useDebugRemoteRuntime = debugRemoteRuntimeUrl.isNotEmpty;
    final readiness = useDebugRemoteRuntime
        ? const ModelArtifactReadiness.ready()
        : await _artifactPreparer.readiness(model: model, targetPath: targetPath);
    if (!readiness.isReady) {
      record = record.copyWith(
        status: ModelInstallStatus.downloading,
        updatedAt: DateTime.now().toUtc(),
      );
      await _registryStore.upsert(record);
      yield ModelInstallProgress(
        modelId: model.id,
        status: ModelInstallStatus.downloading,
        progress: 0,
        message: readiness.message,
      );

      try {
        await _artifactPreparer.prepare(
          model: model,
          targetPath: targetPath,
          requiresWiFi: requiresWiFi,
        );
      } on Object catch (error) {
        final reason = _failureReasonForArtifactMessage(error.toString());
        final failed = record.copyWith(
          status: ModelInstallStatus.failed,
          updatedAt: DateTime.now().toUtc(),
          failureReason: reason,
          errorMessage: error.toString(),
        );
        await _registryStore.upsert(failed);
        yield ModelInstallProgress(
          modelId: model.id,
          status: ModelInstallStatus.failed,
          failureReason: reason,
          message: error.toString(),
        );
        return;
      }

      record = record.copyWith(
        status: ModelInstallStatus.verifying,
        updatedAt: DateTime.now().toUtc(),
      );
      await _registryStore.upsert(record);
      yield ModelInstallProgress(
        modelId: model.id,
        status: ModelInstallStatus.verifying,
      );

      final preparedReadiness = await _artifactPreparer.readiness(
        model: model,
        targetPath: targetPath,
      );
      if (!preparedReadiness.isReady) {
        final reason = _failureReasonForArtifactMessage(
          preparedReadiness.message,
        );
        final failed = record.copyWith(
          status: ModelInstallStatus.failed,
          updatedAt: DateTime.now().toUtc(),
          failureReason: reason,
          errorMessage: preparedReadiness.message,
        );
        await _registryStore.upsert(failed);
        yield ModelInstallProgress(
          modelId: model.id,
          status: ModelInstallStatus.failed,
          failureReason: reason,
          message: preparedReadiness.message,
        );
        return;
      }
    }

    record = record.copyWith(
      status: ModelInstallStatus.installed,
      updatedAt: DateTime.now().toUtc(),
    );
    await _registryStore.upsert(record);
    yield ModelInstallProgress(
      modelId: model.id,
      status: record.status,
      progress: record.status == ModelInstallStatus.installed ? 1 : null,
    );

    yield ModelInstallProgress(
      modelId: model.id,
      status: ModelInstallStatus.loading,
    );
    await _registryStore.upsert(
      record.copyWith(
        status: ModelInstallStatus.loading,
        updatedAt: DateTime.now().toUtc(),
      ),
    );

    try {
      await _runtime.initialize(model.toLlmModelConfig(targetPath));
      final response = await _runtime
          .generateOnce(
            prompt: smokeTestPrompt,
            config: smokeTestGenerationConfig,
          )
          .timeout(smokeTestTimeout);

      final smokeText = response.text.replaceAll('<pad>', '').trim();
      if (smokeText.isEmpty) {
        final failed = record.copyWith(
          status: ModelInstallStatus.failed,
          updatedAt: DateTime.now().toUtc(),
          failureReason: ModelFailureReason.smokeTestFailed,
          errorMessage: 'Smoke test returned empty output.',
        );
        await _registryStore.upsert(failed);
        yield _failed(model, ModelFailureReason.smokeTestFailed);
        return;
      }
      if (!_looksLikeUsableText(smokeText)) {
        final failed = record.copyWith(
          status: ModelInstallStatus.failed,
          updatedAt: DateTime.now().toUtc(),
          failureReason: ModelFailureReason.smokeTestFailed,
          errorMessage: 'Smoke test returned unusable output: $smokeText',
        );
        await _registryStore.upsert(failed);
        yield _failed(model, ModelFailureReason.smokeTestFailed);
        return;
      }
    } on Object catch (error) {
      final failed = record.copyWith(
        status: ModelInstallStatus.failed,
        updatedAt: DateTime.now().toUtc(),
        failureReason: ModelFailureReason.runtimeFailed,
        errorMessage: error.toString(),
      );
      await _registryStore.upsert(failed);
      yield ModelInstallProgress(
        modelId: model.id,
        status: ModelInstallStatus.failed,
        failureReason: ModelFailureReason.runtimeFailed,
        message: error.toString(),
      );
      return;
    }

    await _registryStore.upsert(
      record.copyWith(
        status: ModelInstallStatus.ready,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    yield ModelInstallProgress(
      modelId: model.id,
      status: ModelInstallStatus.ready,
      progress: 1,
    );
  }

  ModelInstallProgress _failed(
    ModelManifestEntry model,
    ModelFailureReason reason,
  ) {
    return ModelInstallProgress(
      modelId: model.id,
      status: ModelInstallStatus.failed,
      failureReason: reason,
    );
  }

  ModelFailureReason _failureReasonForArtifactMessage(String? message) {
    final normalized = message?.toLowerCase() ?? '';
    if (normalized.contains('hash') || normalized.contains('sha-256')) {
      return ModelFailureReason.hashMismatch;
    }
    return ModelFailureReason.downloadFailed;
  }

  bool _looksLikeUsableText(String text) {
    final normalized = text.replaceAll('<pad>', '').trim();
    if (normalized.isEmpty) {
      return false;
    }
    final asciiLetters = RegExp(r'[A-Za-z]').allMatches(normalized).length;
    final visibleAscii = RegExp(
      r'[A-Za-z0-9 .,;:!?()-]',
    ).allMatches(normalized).length;
    return asciiLetters >= 8 && visibleAscii / normalized.length >= 0.55;
  }
}
