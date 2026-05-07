import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

abstract interface class HuggingFaceModelRepository {
  Future<List<String>> listFiles({
    required String repoId,
    required String revision,
  });

  Future<void> downloadFile({
    required String repoId,
    required String revision,
    required String remotePath,
    required String destinationPath,
  });
}

class HuggingFaceHubModelRepository implements HuggingFaceModelRepository {
  HuggingFaceHubModelRepository({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  static const String _host = 'huggingface.co';
  static const int _maxAttempts = 4;

  final HttpClient _httpClient;

  @override
  Future<List<String>> listFiles({
    required String repoId,
    required String revision,
  }) async {
    final uri = Uri(
      scheme: 'https',
      host: _host,
      pathSegments: <String>[
        'api',
        'models',
        ...repoId.split('/'),
        'revision',
        revision,
      ],
    );
    final body = await _withRetries(() => _readText(uri));
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Hugging Face model response is invalid.');
    }

    final siblings = decoded['siblings'];
    if (siblings is! List<Object?>) {
      throw const FormatException('Hugging Face model response has no files.');
    }

    final files = <String>[];
    for (final sibling in siblings) {
      if (sibling is Map<String, Object?>) {
        final path = sibling['rfilename'];
        if (path is String && _isSafeRemotePath(path)) {
          files.add(path);
        }
      }
    }
    return files;
  }

  @override
  Future<void> downloadFile({
    required String repoId,
    required String revision,
    required String remotePath,
    required String destinationPath,
  }) async {
    if (!_isSafeRemotePath(remotePath)) {
      throw ArgumentError.value(remotePath, 'remotePath', 'Unsafe remote path.');
    }

    final uri = Uri(
      scheme: 'https',
      host: _host,
      pathSegments: <String>[
        ...repoId.split('/'),
        'resolve',
        revision,
        ...remotePath.split('/'),
      ],
      queryParameters: <String, String>{'download': 'true'},
    );
    final destination = File(destinationPath);
    await destination.parent.create(recursive: true);
    if (await destination.exists() && await destination.length() > 0) {
      return;
    }
    final tempFile = File('${destination.path}.download');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    await _withRetries(() => _downloadToTempAndMove(uri, remotePath, tempFile, destination));
  }

  Future<void> _downloadToTempAndMove(
    Uri uri,
    String remotePath,
    File tempFile,
    File destination,
  ) async {
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final request = await _httpClient.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'GemmaLocal/1.0');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Failed to download $remotePath: HTTP ${response.statusCode}.',
        uri: uri,
      );
    }

    final sink = tempFile.openWrite();
    await response.pipe(sink);
    if (await destination.exists()) {
      await destination.delete();
    }
    await tempFile.rename(destination.path);
  }

  Future<String> _readText(Uri uri) async {
    final request = await _httpClient.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'GemmaLocal/1.0');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Hugging Face request failed: HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    return utf8.decode(await response.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    ));
  }

  Future<T> _withRetries<T>(Future<T> Function() action) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt += 1) {
      try {
        return await action();
      } on Object catch (error) {
        lastError = error;
        if (attempt == _maxAttempts) {
          break;
        }
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
    throw lastError ?? StateError('Hugging Face request failed.');
  }

  bool _isSafeRemotePath(String remotePath) {
    if (remotePath.isEmpty || p.isAbsolute(remotePath)) {
      return false;
    }
    return !remotePath.split('/').contains('..');
  }
}
