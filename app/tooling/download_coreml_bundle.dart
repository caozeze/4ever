import 'dart:convert';
import 'dart:io';

import 'package:gemma_local/data/model/model_artifact_preparers.dart';
import 'package:gemma_local/domain/ai/model_manifest.dart';

Future<void> main(List<String> arguments) async {
  final targetPath = arguments.isEmpty
      ? '/private/tmp/gemma-coreml-full/n1024'
      : arguments.first;
  final manifestFile = File('assets/model_manifest.json');
  final decoded = jsonDecode(await manifestFile.readAsString());
  final manifest = ModelManifest.fromJson(decoded as Map<String, Object?>);
  final model = manifest.byId('gemma-4-e2b-it-coreml-ios');
  final preparer = CoreMlN1024BundleReadiness();

  stdout.writeln('target=$targetPath');
  stdout.writeln('model=${model.id}');
  stdout.writeln('repo=${model.repoId}');
  stdout.writeln('revision=${model.revision}');

  final before = await preparer.readiness(model: model, targetPath: targetPath);
  stdout.writeln('before_ready=${before.isReady}');
  if (before.message != null) {
    stdout.writeln('before_message=${before.message}');
  }

  final prepared = await preparer.prepare(model: model, targetPath: targetPath);
  stdout.writeln('prepared_ready=${prepared.isReady}');
  if (prepared.message != null) {
    stdout.writeln('prepared_message=${prepared.message}');
  }

  final after = await preparer.readiness(model: model, targetPath: targetPath);
  stdout.writeln('after_ready=${after.isReady}');
  if (after.message != null) {
    stdout.writeln('after_message=${after.message}');
  }

  if (!after.isReady) {
    exitCode = 1;
  }
}
