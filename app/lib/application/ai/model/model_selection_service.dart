import '../../../domain/ai/device_capabilities.dart';
import '../../../domain/ai/model_manifest.dart';
import '../../../domain/ai/model_manifest_entry.dart';

class ModelSelectionService {
  const ModelSelectionService();

  ModelManifestEntry select({
    required ModelManifest manifest,
    required DeviceCapabilities capabilities,
    String? preferredModelId,
  }) {
    final compatibleModels =
        manifest.models
            .where((model) => model.supportsPlatform(capabilities.platform))
            .where((model) => model.minMemoryGb <= capabilities.totalMemoryGb)
            .toList()
          ..sort((a, b) => a.selectionPriority.compareTo(b.selectionPriority));

    if (compatibleModels.isEmpty) {
      throw StateError('No compatible Gemma 4 model for this device.');
    }

    if (preferredModelId != null) {
      for (final model in compatibleModels) {
        if (model.id == preferredModelId) {
          return model;
        }
      }
    }

    for (final model in compatibleModels) {
      if (model.isDefault) {
        return model;
      }
    }

    return compatibleModels.first;
  }
}
