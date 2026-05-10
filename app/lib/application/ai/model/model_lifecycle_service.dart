import '../../../domain/ai/device_capabilities.dart';
import '../../../domain/ai/llm_runtime.dart';
import '../../../domain/ai/model_failure_reason.dart';
import '../../../domain/ai/model_install_progress.dart';
import '../../../domain/ai/model_install_record.dart';
import '../../../domain/ai/model_install_status.dart';
import '../../../domain/ai/model_manifest_entry.dart';
import '../../observability/agent_trace_sink.dart';
import 'demo_model_identity.dart';
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
    AgentTraceSink traceSink = const NoopAgentTraceSink(),
  }) : _catalog = catalog,
       _deviceCapabilitiesReader = deviceCapabilitiesReader,
       _selectionService = selectionService,
       _storagePaths = storagePaths,
       _artifactPreparer = artifactPreparer,
       _registryStore = registryStore,
       _runtime = runtime,
       _traceSink = traceSink;

  final ModelCatalog _catalog;
  final DeviceCapabilitiesReader _deviceCapabilitiesReader;
  final ModelSelectionService _selectionService;
  final ModelStoragePaths _storagePaths;
  final ModelArtifactPreparer _artifactPreparer;
  final ModelRegistryStore _registryStore;
  final LlmRuntime _runtime;
  final AgentTraceSink _traceSink;

  Stream<ModelInstallProgress> ensureDemoModelReady({
    String? preferredModelId,
    bool requiresWiFi = true,
  }) async* {
    final capabilities = await _deviceCapabilitiesReader.read();
    final manifest = await _catalog.load();
    final model = _selectionService.select(
      manifest: manifest,
      capabilities: capabilities,
      preferredModelId: DemoModelIdentity.modelId,
    );

    yield* ensureLocalGemma(
      model: model,
      capabilities: capabilities,
      requiresWiFi: requiresWiFi,
    );
  }

  Stream<ModelInstallProgress> installAndLoad({
    required ModelManifestEntry model,
    required DeviceCapabilities capabilities,
    bool requiresWiFi = true,
  }) {
    return ensureLocalGemma(
      model: model,
      capabilities: capabilities,
      requiresWiFi: requiresWiFi,
    );
  }

  Stream<ModelInstallProgress> ensureLocalGemma({
    required ModelManifestEntry model,
    required DeviceCapabilities capabilities,
    bool requiresWiFi = true,
  }) async* {
    final now = DateTime.now().toUtc();
    final targetPath = await _storagePaths.modelFilePath(model);
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

    _trace('model_artifact_check_start', modelId: model.id, status: 'checking');
    yield ModelInstallProgress(
      modelId: model.id,
      status: ModelInstallStatus.notInstalled,
      message: 'Checking local Gemma...',
    );
    final readiness = await _artifactPreparer.readiness(
      model: model,
      targetPath: targetPath,
    );
    _trace(
      readiness.isReady ? 'model_artifact_found' : 'model_artifact_missing',
      modelId: model.id,
      status: readiness.isReady ? 'ready' : 'missing',
    );
    if (!readiness.isReady) {
      yield* _markFailed(
        record: record,
        model: model,
        reason: ModelFailureReason.modelNotFound,
        message:
            readiness.message ?? 'Local Gemma model is missing at $targetPath.',
      );
      return;
    }

    final runtimeStatus = await _runtime.getStatus();
    if (runtimeStatus.state == 'ready' &&
        runtimeStatus.loadedModelId == model.id) {
      final ready = record.copyWith(
        status: ModelInstallStatus.ready,
        updatedAt: DateTime.now().toUtc(),
      );
      await _registryStore.upsert(ready);
      _trace('model_connection_ready', modelId: model.id, status: 'ready');
      yield ModelInstallProgress(
        modelId: model.id,
        status: ModelInstallStatus.ready,
        progress: 1,
      );
      return;
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
      _trace('model_initialize_start', modelId: model.id, status: 'loading');
      await _runtime.initialize(model.toLlmModelConfig(targetPath));
    } on Object catch (error) {
      _trace(
        'model_initialize_failed',
        modelId: model.id,
        status: 'failed',
        errorCode: ModelFailureReason.runtimeFailed.name,
      );
      yield* _markFailed(
        record: record,
        model: model,
        reason: ModelFailureReason.runtimeFailed,
        message: error.toString(),
      );
      return;
    }
    _trace('model_initialize_ready', modelId: model.id, status: 'ready');

    final loadedStatus = await _runtime.getStatus();
    if (loadedStatus.state != 'ready' ||
        loadedStatus.loadedModelId != model.id) {
      yield* _markFailed(
        record: record,
        model: model,
        reason: ModelFailureReason.runtimeFailed,
        message: 'Local Gemma initialized but runtime status is not ready.',
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
    _trace('model_connection_ready', modelId: model.id, status: 'ready');
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

  Stream<ModelInstallProgress> _markFailed({
    required ModelInstallRecord record,
    required ModelManifestEntry model,
    required ModelFailureReason reason,
    required String message,
  }) async* {
    final failed = record.copyWith(
      status: ModelInstallStatus.failed,
      updatedAt: DateTime.now().toUtc(),
      failureReason: reason,
      errorMessage: message,
    );
    await _registryStore.upsert(failed);
    yield ModelInstallProgress(
      modelId: model.id,
      status: ModelInstallStatus.failed,
      failureReason: reason,
      message: message,
    );
  }

  void _trace(
    String event, {
    required String modelId,
    String? status,
    String? errorCode,
  }) {
    _traceSink.record(
      AgentTraceEvent(
        event: event,
        modelId: modelId,
        status: status,
        errorCode: errorCode,
        phase: 'model_lifecycle',
      ),
    );
  }
}
