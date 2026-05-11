import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../application/ai/model/model_artifact_preparer.dart';
import '../../domain/ai/model_manifest_entry.dart';

class CoreMlN1024BundleReadiness implements ModelArtifactInstaller {
  CoreMlN1024BundleReadiness({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const _sharedRequiredRelativePaths = <String>[
    'model_config.json',
    'hf_model/config.json',
    'hf_model/tokenizer.json',
    'hf_model/tokenizer_config.json',
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
    if (model.runtime != 'coreml_llm' ||
        model.artifactType != 'coreml_bundle') {
      return ModelArtifactReadiness.missing(
        'CoreML bundle installer does not support ${model.runtime}/${model.artifactType}.',
      );
    }

    final directory = Directory(targetPath);
    if (!await directory.exists()) {
      return ModelArtifactReadiness.missing(
        'Local Gemma model is missing at $targetPath.',
      );
    }

    for (final relativePath in _requiredRelativePaths(model)) {
      final file = File(p.join(targetPath, relativePath));
      if (!await file.exists() || await file.length() == 0) {
        return ModelArtifactReadiness.missing(
          'Local Gemma model is missing $relativePath at $targetPath.',
        );
      }
    }

    return const ModelArtifactReadiness.ready();
  }

  @override
  Future<ModelArtifactReadiness> prepare({
    required ModelManifestEntry model,
    required String targetPath,
  }) async {
    if (model.runtime != 'coreml_llm' ||
        model.artifactType != 'coreml_bundle') {
      return ModelArtifactReadiness.missing(
        'CoreML bundle installer does not support ${model.runtime}/${model.artifactType}.',
      );
    }
    if (model.repoId == null || model.allowPatterns.isEmpty) {
      return ModelArtifactReadiness.missing(
        'CoreML bundle download is missing repo metadata for ${model.id}.',
      );
    }

    try {
      final files = await _listHuggingFaceFiles(model);
      if (files.isEmpty) {
        return ModelArtifactReadiness.missing(
          'No downloadable CoreML files matched allow_patterns for ${model.id}.',
        );
      }
      for (final file in files) {
        try {
          await _downloadFile(
            model: model,
            remotePath: file,
            targetPath: targetPath,
          );
        } on DioException catch (error) {
          return ModelArtifactReadiness.missing(
            'CoreML bundle download failed for ${model.id} at $file: ${_describeDio(error)}',
          );
        } on FileSystemException catch (error) {
          return ModelArtifactReadiness.missing(
            'CoreML bundle write failed for ${model.id} at $file: ${error.message}',
          );
        } on Object catch (error) {
          return ModelArtifactReadiness.missing(
            'CoreML bundle download failed for ${model.id} at $file: $error',
          );
        }
      }
      return readiness(model: model, targetPath: targetPath);
    } on DioException catch (error) {
      return ModelArtifactReadiness.missing(
        'CoreML bundle download failed for ${model.id}: ${error.message}',
      );
    } on FileSystemException catch (error) {
      return ModelArtifactReadiness.missing(
        'CoreML bundle write failed for ${model.id}: ${error.message}',
      );
    }
  }

  Future<List<String>> _listHuggingFaceFiles(ModelManifestEntry model) async {
    final repoId = model.repoId!;
    final url =
        'https://huggingface.co/api/models/$repoId/tree/${model.revision}';
    final response = await _dio.get<List<Object?>>(
      url,
      queryParameters: const <String, Object?>{'recursive': '1'},
    );
    final body = response.data ?? const <Object?>[];
    final files = <String>[];
    for (final item in body) {
      if (item is! Map) {
        continue;
      }
      final path = item['path'];
      final type = item['type'];
      if (path is String &&
          (type == 'file' || type == null) &&
          _isAllowed(path, model.allowPatterns)) {
        files.add(path);
      }
    }
    files.sort();
    return files;
  }

  Future<void> _downloadFile({
    required ModelManifestEntry model,
    required String remotePath,
    required String targetPath,
  }) async {
    final localPath = p.join(targetPath, _localRelativePath(remotePath));
    final output = File(localPath);
    if (await output.exists() && await output.length() > 0) {
      return;
    }
    await output.parent.create(recursive: true);
    final tempPath = '$localPath.download';
    final url = _resolveUrl(model: model, remotePath: remotePath);
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt += 1) {
      try {
        await _dio.download(url, tempPath, deleteOnError: true);
        lastError = null;
        break;
      } on DioException catch (error) {
        lastError = error;
        try {
          await _downloadWithHttpClient(url: url, tempPath: tempPath);
          lastError = null;
          break;
        } on Object catch (fallbackError) {
          lastError = fallbackError;
        }
      }
      if (attempt < 3) {
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
    if (lastError != null) {
      if (lastError is DioException) {
        throw lastError;
      }
      throw FileSystemException(lastError.toString(), tempPath);
    }
    final tempFile = File(tempPath);
    if (!await tempFile.exists() || await tempFile.length() == 0) {
      throw FileSystemException('Downloaded empty file.', tempPath);
    }
    if (await output.exists()) {
      await output.delete();
    }
    await tempFile.rename(localPath);
  }

  bool _isAllowed(String remotePath, List<String> allowPatterns) {
    return allowPatterns.any((pattern) => _matchesGlob(remotePath, pattern));
  }

  bool _matchesGlob(String value, String pattern) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < pattern.length; i += 1) {
      final char = pattern[i];
      if (char == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          buffer.write('.*');
          i += 1;
        } else {
          buffer.write('[^/]*');
        }
      } else {
        buffer.write(RegExp.escape(char));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString()).hasMatch(value);
  }

  String _localRelativePath(String remotePath) {
    final normalized = p.posix.normalize(remotePath);
    if (normalized.startsWith('../') || p.posix.isAbsolute(normalized)) {
      throw FileSystemException('Unsafe remote path.', remotePath);
    }
    if (normalized.startsWith('swa/')) {
      return normalized.substring('swa/'.length);
    }
    return normalized;
  }

  List<String> _requiredRelativePaths(ModelManifestEntry model) {
    final chunkPaths = model.id.contains('e4b')
        ? const <String>[
            'chunk1.mlmodelc/coremldata.bin',
            'chunk2.mlmodelc/coremldata.bin',
            'chunk3.mlmodelc/coremldata.bin',
            'chunk4.mlmodelc/coremldata.bin',
          ]
        : const <String>[
            'chunk1.mlmodelc/coremldata.bin',
            'chunk2_3way.mlmodelc/coremldata.bin',
            'chunk3_3way.mlmodelc/coremldata.bin',
          ];
    return <String>[..._sharedRequiredRelativePaths, ...chunkPaths];
  }

  String _resolveUrl({
    required ModelManifestEntry model,
    required String remotePath,
  }) {
    final encodedPath = remotePath
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return 'https://huggingface.co/${model.repoId}/resolve/${model.revision}/$encodedPath?download=true';
  }

  Future<void> _downloadWithHttpClient({
    required String url,
    required String tempPath,
  }) async {
    final client = HttpClient();
    try {
      var uri = Uri.parse(url);
      for (var redirectCount = 0; redirectCount < 5; redirectCount += 1) {
        final request = await client.getUrl(uri);
        final response = await request.close();
        if (response.isRedirect && response.headers.value('location') != null) {
          uri = uri.resolve(response.headers.value('location')!);
          await response.drain<void>();
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>();
          throw HttpException(
            'HTTP ${response.statusCode} while downloading $uri',
            uri: uri,
          );
        }
        final output = File(tempPath);
        final sink = output.openWrite();
        try {
          await response.pipe(sink);
        } finally {
          await sink.close();
        }
        return;
      }
      throw HttpException('Too many redirects while downloading $url');
    } finally {
      client.close(force: true);
    }
  }

  String _describeDio(DioException error) {
    final statusCode = error.response?.statusCode;
    final statusMessage = error.response?.statusMessage;
    final message = error.message;
    return [
      if (statusCode != null) 'status=$statusCode',
      if (statusMessage != null && statusMessage.isNotEmpty)
        'statusMessage=$statusMessage',
      if (message != null && message.isNotEmpty) 'message=$message',
      'type=${error.type.name}',
    ].join(' ');
  }
}
