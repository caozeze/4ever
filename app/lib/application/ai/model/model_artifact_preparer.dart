import '../../../domain/ai/model_manifest_entry.dart';
import 'model_file_downloader.dart';

class ModelArtifactReadiness {
  const ModelArtifactReadiness.ready() : isReady = true, message = null;

  const ModelArtifactReadiness.missing(this.message) : isReady = false;

  final bool isReady;
  final String? message;
}

abstract interface class ModelArtifactPreparer {
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  });

  Future<void> prepare({
    required ModelManifestEntry model,
    required String targetPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  });
}
