import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../application/ai/model/model_artifact_preparer.dart';
import '../../application/ai/model/model_file_downloader.dart';
import '../../application/ai/model/model_file_verifier.dart';
import '../../domain/ai/model_manifest_entry.dart';
import 'hugging_face_model_repository.dart';

class DefaultModelArtifactPreparer implements ModelArtifactPreparer {
  DefaultModelArtifactPreparer({
    required ModelFileDownloader fileDownloader,
    required ModelFileVerifier fileVerifier,
    required HuggingFaceModelRepository huggingFaceRepository,
  }) : _filePreparer = FileModelArtifactPreparer(
         downloader: fileDownloader,
         verifier: fileVerifier,
       ),
       _bundlePreparer = CoreMlBundleArtifactPreparer(
         repository: huggingFaceRepository,
       );

  final FileModelArtifactPreparer _filePreparer;
  final CoreMlBundleArtifactPreparer _bundlePreparer;

  @override
  Future<void> prepare({
    required ModelManifestEntry model,
    required String targetPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  }) {
    return _for(model).prepare(
      model: model,
      targetPath: targetPath,
      requiresWiFi: requiresWiFi,
      onProgress: onProgress,
    );
  }

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) {
    return _for(model).readiness(model: model, targetPath: targetPath);
  }

  ModelArtifactPreparer _for(ModelManifestEntry model) {
    if (model.isBundleArtifact) {
      return _bundlePreparer;
    }
    return _filePreparer;
  }
}

class FileModelArtifactPreparer implements ModelArtifactPreparer {
  const FileModelArtifactPreparer({
    required ModelFileDownloader downloader,
    required ModelFileVerifier verifier,
  }) : _downloader = downloader,
       _verifier = verifier;

  final ModelFileDownloader _downloader;
  final ModelFileVerifier _verifier;

  @override
  Future<void> prepare({
    required ModelManifestEntry model,
    required String targetPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    if (model.downloadUrl.isEmpty) {
      throw StateError('Model ${model.id} has no download_url.');
    }

    await _downloader.download(
      model: model,
      destinationPath: targetPath,
      requiresWiFi: requiresWiFi,
      onProgress: onProgress,
    );

    if (model.sha256 != 'TO_BE_FILLED') {
      final hashMatches = await _verifier.verifySha256(
        path: targetPath,
        expectedSha256: model.sha256,
      );
      if (!hashMatches) {
        throw StateError('SHA-256 mismatch for ${model.id}.');
      }
    }
  }

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    if (!await _verifier.exists(targetPath)) {
      return const ModelArtifactReadiness.missing('model file is missing');
    }

    if (model.sha256 == 'TO_BE_FILLED') {
      return const ModelArtifactReadiness.ready();
    }

    final length = await _verifier.length(targetPath);
    if (length != model.sizeBytes) {
      return ModelArtifactReadiness.missing(
        'model file size is $length bytes; expected ${model.sizeBytes}',
      );
    }

    final hashMatches = await _verifier.verifySha256(
      path: targetPath,
      expectedSha256: model.sha256,
    );
    if (!hashMatches) {
      return const ModelArtifactReadiness.missing('model file hash mismatch');
    }

    return const ModelArtifactReadiness.ready();
  }
}

class CoreMlBundleArtifactPreparer implements ModelArtifactPreparer {
  const CoreMlBundleArtifactPreparer({
    required HuggingFaceModelRepository repository,
  }) : _repository = repository;

  final HuggingFaceModelRepository _repository;

  @override
  Future<void> prepare({
    required ModelManifestEntry model,
    required String targetPath,
    required bool requiresWiFi,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    if (_isZipBundle(model)) {
      await _prepareZipBundle(
        model: model,
        targetPath: targetPath,
        onProgress: onProgress,
      );
      return;
    }

    final repoId = model.repoId;
    if (repoId == null || repoId.isEmpty) {
      throw StateError('CoreML bundle model ${model.id} has no repo_id.');
    }

    final files = await _repository.listFiles(
      repoId: repoId,
      revision: model.revision,
    );
    final selectedFiles =
        files.where((file) => _isAllowed(file, model.allowPatterns)).toList()
          ..sort();

    if (selectedFiles.isEmpty) {
      throw StateError('No files matched allow_patterns for ${model.id}.');
    }

    var completed = 0;
    for (final remotePath in selectedFiles) {
      await _repository.downloadFile(
        repoId: repoId,
        revision: model.revision,
        remotePath: remotePath,
        destinationPath: p.join(targetPath, _localPathFor(remotePath)),
      );
      completed += 1;
      onProgress?.call(completed / selectedFiles.length);
    }

    final result = await readiness(model: model, targetPath: targetPath);
    if (!result.isReady) {
      throw StateError(
        result.message ?? 'Downloaded CoreML bundle is not ready.',
      );
    }
  }

  Future<void> _prepareZipBundle({
    required ModelManifestEntry model,
    required String targetPath,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    final targetDirectory = Directory(targetPath);
    if (await targetDirectory.exists()) {
      await targetDirectory.delete(recursive: true);
    }
    await targetDirectory.create(recursive: true);

    final zipPath = '$targetPath.download.zip';
    final zipFile = File(zipPath);
    if (await zipFile.exists()) {
      await zipFile.delete();
    }

    await _downloadZip(
      url: model.downloadUrl,
      destination: zipFile,
      onProgress: onProgress,
    );
    try {
      await extractFileToDisk(zipPath, targetPath);
    } finally {
      if (await zipFile.exists()) {
        await zipFile.delete();
      }
    }

    final result = await readiness(model: model, targetPath: targetPath);
    if (!result.isReady) {
      throw StateError(
        result.message ?? 'Extracted CoreML bundle is not ready.',
      );
    }
  }

  Future<void> _downloadZip({
    required String url,
    required File destination,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    final uri = Uri.parse(url);
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'GemmaLocal/1.0');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Failed to download CoreML zip: HTTP ${response.statusCode}.',
          uri: uri,
        );
      }

      final total = response.contentLength;
      var received = 0;
      final sink = destination.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            onProgress?.call(received / total);
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<ModelArtifactReadiness> readiness({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    final directory = Directory(targetPath);
    if (!await directory.exists()) {
      return const ModelArtifactReadiness.missing(
        'CoreML bundle directory is missing',
      );
    }

    final config = File(p.join(targetPath, 'model_config.json'));
    if (!await config.exists()) {
      return const ModelArtifactReadiness.missing('missing model_config.json');
    }

    final tokenizer = Directory(p.join(targetPath, 'hf_model'));
    if (!await tokenizer.exists()) {
      return const ModelArtifactReadiness.missing('missing hf_model tokenizer');
    }

    final missingTokenizer = await _firstMissingFile(targetPath, const <String>[
      'hf_model/tokenizer.json',
      'hf_model/tokenizer_config.json',
    ]);
    if (missingTokenizer != null) {
      return ModelArtifactReadiness.missing('missing $missingTokenizer');
    }

    if (await _containsMonolithicModel(directory)) {
      return const ModelArtifactReadiness.ready();
    }

    final missingChunkedFile =
        await _firstMissingFile(targetPath, const <String>[
          'chunk1.mlmodelc/coremldata.bin',
          'chunk2_3way.mlmodelc/coremldata.bin',
          'chunk3_3way.mlmodelc/coremldata.bin',
          'embed_tokens_q8.bin',
          'embed_tokens_scales.bin',
          'embed_tokens_per_layer_q8.bin',
          'embed_tokens_per_layer_scales.bin',
          'per_layer_projection.bin',
        ]);
    if (missingChunkedFile == null) {
      return const ModelArtifactReadiness.ready();
    }

    final hasCompiledModel = await _containsCompiledModel(directory);
    if (!hasCompiledModel) {
      return const ModelArtifactReadiness.missing(
        'missing .mlmodelc or .mlpackage',
      );
    }

    return ModelArtifactReadiness.missing('missing $missingChunkedFile');
  }

  bool _isZipBundle(ModelManifestEntry model) {
    return model.downloadUrl.toLowerCase().endsWith('.zip');
  }

  String _localPathFor(String remotePath) {
    if (remotePath.startsWith('swa/')) {
      return remotePath.substring('swa/'.length);
    }
    return remotePath;
  }

  Future<String?> _firstMissingFile(
    String targetPath,
    List<String> relativePaths,
  ) async {
    for (final relativePath in relativePaths) {
      if (!await File(p.join(targetPath, relativePath)).exists()) {
        return relativePath;
      }
    }
    return null;
  }

  Future<bool> _containsCompiledModel(Directory directory) async {
    await for (final entity in directory.list(recursive: true)) {
      final basename = p.basename(entity.path);
      if (basename.endsWith('.mlmodelc') || basename.endsWith('.mlpackage')) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _containsMonolithicModel(Directory directory) async {
    final modelc = Directory(p.join(directory.path, 'model.mlmodelc'));
    if (await File(p.join(modelc.path, 'weights/weight.bin')).exists() ||
        await File(p.join(modelc.path, 'coremldata.bin')).exists()) {
      return true;
    }

    final package = Directory(p.join(directory.path, 'model.mlpackage'));
    return File(
      p.join(package.path, 'Data/com.apple.CoreML/weights/weight.bin'),
    ).exists();
  }

  bool _isAllowed(String remotePath, List<String> allowPatterns) {
    if (allowPatterns.isEmpty) {
      return true;
    }
    for (final pattern in allowPatterns) {
      if (_matchesPattern(remotePath, pattern)) {
        return true;
      }
    }
    return false;
  }

  bool _matchesPattern(String remotePath, String pattern) {
    if (pattern == remotePath) {
      return true;
    }
    if (pattern == '*.json') {
      return remotePath.endsWith('.json');
    }
    if (pattern == '*.bin') {
      return remotePath.endsWith('.bin');
    }
    if (pattern == '*.txt') {
      return remotePath.endsWith('.txt');
    }
    if (pattern == '*.npy') {
      return remotePath.endsWith('.npy');
    }
    if (pattern == '*.mlmodelc/**') {
      return remotePath
          .split('/')
          .any((segment) => segment.endsWith('.mlmodelc'));
    }
    if (pattern == '*.mlpackage/**') {
      return remotePath
          .split('/')
          .any((segment) => segment.endsWith('.mlpackage'));
    }
    if (pattern.endsWith('/**')) {
      final prefix = pattern.substring(0, pattern.length - 3);
      return remotePath == prefix || remotePath.startsWith('$prefix/');
    }
    if (pattern.startsWith('*.')) {
      return remotePath.endsWith(pattern.substring(1));
    }
    return false;
  }
}
