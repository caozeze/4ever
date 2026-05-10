import '../../../domain/ai/model_manifest_entry.dart';

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
}
