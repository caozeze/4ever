import 'dart:io';

import 'package:path/path.dart' as p;

import '../../application/ai/model/demo_model_identity.dart';
import '../../application/ai/model/model_artifact_preparer.dart';
import '../../domain/ai/model_manifest_entry.dart';

class CoreMlN1024BundleReadiness implements ModelArtifactPreparer {
  const CoreMlN1024BundleReadiness();

  static const requiredRelativePaths = <String>[
    'model_config.json',
    'hf_model/config.json',
    'hf_model/tokenizer.json',
    'hf_model/tokenizer_config.json',
    'chunk1.mlmodelc/coremldata.bin',
    'chunk2_3way.mlmodelc/coremldata.bin',
    'chunk3_3way.mlmodelc/coremldata.bin',
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
  ];

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    if (model.id != DemoModelIdentity.modelId ||
        model.revision != DemoModelIdentity.revision ||
        model.runtime != 'coreml_llm' ||
        model.artifactType != 'coreml_bundle') {
      return const ModelArtifactReadiness.missing(
        'Demo only supports ${DemoModelIdentity.modelId}/${DemoModelIdentity.revision}.',
      );
    }

    final directory = Directory(targetPath);
    if (!await directory.exists()) {
      return ModelArtifactReadiness.missing(
        'Local Gemma model is missing at $targetPath.',
      );
    }

    for (final relativePath in requiredRelativePaths) {
      final file = File(p.join(targetPath, relativePath));
      if (!await file.exists() || await file.length() == 0) {
        return ModelArtifactReadiness.missing(
          'Local Gemma model is missing $relativePath at $targetPath.',
        );
      }
    }

    return const ModelArtifactReadiness.ready();
  }
}
