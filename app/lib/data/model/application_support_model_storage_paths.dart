import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../application/ai/model/demo_model_identity.dart';
import '../../application/ai/model/model_storage_paths.dart';
import '../../domain/ai/model_manifest_entry.dart';

class ApplicationSupportModelStoragePaths implements ModelStoragePaths {
  const ApplicationSupportModelStoragePaths({this.rootDirectoryProvider});

  final Future<Directory> Function()? rootDirectoryProvider;

  @override
  Future<String> registryFilePath() async {
    final root = await _rootDirectory();
    return p.join(root.path, 'model_registry.json');
  }

  @override
  Future<String> modelFilePath(ModelManifestEntry model) async {
    final root = await _rootDirectory();
    final directory = Directory(
      p.join(
        root.path,
        'models',
        DemoModelIdentity.modelId,
        DemoModelIdentity.revision,
      ),
    );
    await directory.create(recursive: true);
    return directory.path;
  }

  Future<Directory> _rootDirectory() {
    return rootDirectoryProvider?.call() ?? getApplicationSupportDirectory();
  }
}
