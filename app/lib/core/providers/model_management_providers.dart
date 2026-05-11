import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../application/ai/demo_chat_controller.dart';
import '../../application/ai/local_health_agent_service.dart';
import '../../application/ai/model/device_capabilities_reader.dart';
import '../../application/ai/model/model_artifact_preparer.dart';
import '../../application/ai/model/model_catalog.dart';
import '../../application/ai/model/model_connection_controller.dart';
import '../../application/ai/model/model_lifecycle_service.dart';
import '../../application/ai/model/model_registry_store.dart';
import '../../application/ai/model/model_selection_service.dart';
import '../../application/ai/model/model_storage_paths.dart';
import '../../data/model/application_support_model_storage_paths.dart';
import '../../data/model/asset_model_catalog.dart';
import '../../data/model/json_model_registry_store.dart';
import '../../data/model/model_artifact_preparers.dart';
import '../native/device_capabilities_channel_reader.dart';
import 'health_providers.dart';
import 'native_providers.dart';

final modelCatalogProvider = Provider<ModelCatalog>((Ref ref) {
  return const AssetModelCatalog();
});

final modelSelectionServiceProvider = Provider<ModelSelectionService>((
  Ref ref,
) {
  return const ModelSelectionService();
});

final modelStoragePathsProvider = Provider<ModelStoragePaths>((Ref ref) {
  return const ApplicationSupportModelStoragePaths();
});

final modelArtifactPreparerProvider = Provider<ModelArtifactPreparer>((
  Ref ref,
) {
  return CoreMlN1024BundleReadiness();
});

final deviceCapabilitiesReaderProvider = Provider<DeviceCapabilitiesReader>((
  Ref ref,
) {
  return DeviceCapabilitiesChannelReader();
});

final modelRegistryStoreProvider = FutureProvider<ModelRegistryStore>((
  Ref ref,
) async {
  final paths = ref.watch(modelStoragePathsProvider);
  return JsonModelRegistryStore(registryPath: await paths.registryFilePath());
});

final modelLifecycleServiceProvider = FutureProvider<ModelLifecycleService>((
  Ref ref,
) async {
  return ModelLifecycleService(
    catalog: ref.watch(modelCatalogProvider),
    deviceCapabilitiesReader: ref.watch(deviceCapabilitiesReaderProvider),
    selectionService: ref.watch(modelSelectionServiceProvider),
    storagePaths: ref.watch(modelStoragePathsProvider),
    artifactPreparer: ref.watch(modelArtifactPreparerProvider),
    registryStore: await ref.watch(modelRegistryStoreProvider.future),
    runtime: ref.watch(llmRuntimeProvider),
    traceSink: ref.watch(agentTraceSinkProvider),
  );
});

final demoChatControllerProvider = FutureProvider<DemoChatController>((
  Ref ref,
) async {
  final runtime = ref.watch(llmRuntimeProvider);
  return DemoChatController(
    catalog: ref.watch(modelCatalogProvider),
    deviceCapabilitiesReader: ref.watch(deviceCapabilitiesReaderProvider),
    selectionService: ref.watch(modelSelectionServiceProvider),
    lifecycleService: await ref.watch(modelLifecycleServiceProvider.future),
    runtime: runtime,
    localHealthAgentService: DartanticLocalHealthAgentService(
      runtime: runtime,
      healthSummaryService: ref.watch(healthSummaryServiceProvider),
      traceSink: ref.watch(agentTraceSinkProvider),
    ),
  );
});

final modelConnectionControllerProvider =
    ChangeNotifierProvider<ModelConnectionController>((Ref ref) {
      return ModelConnectionController(
        loadController: () => ref.read(demoChatControllerProvider.future),
      );
    });
