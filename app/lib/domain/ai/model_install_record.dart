import 'model_failure_reason.dart';
import 'model_install_status.dart';

class ModelInstallRecord {
  const ModelInstallRecord({
    required this.modelId,
    required this.displayName,
    required this.localPath,
    required this.sha256,
    required this.sizeBytes,
    required this.sourceCommit,
    required this.runtime,
    required this.artifactType,
    required this.revision,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.failureReason,
    this.errorMessage,
  });

  final String modelId;
  final String displayName;
  final String? localPath;
  final String sha256;
  final int sizeBytes;
  final String sourceCommit;
  final String runtime;
  final String artifactType;
  final String revision;
  final ModelInstallStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ModelFailureReason? failureReason;
  final String? errorMessage;

  ModelInstallRecord copyWith({
    String? localPath,
    ModelInstallStatus? status,
    DateTime? updatedAt,
    ModelFailureReason? failureReason,
    String? errorMessage,
  }) {
    return ModelInstallRecord(
      modelId: modelId,
      displayName: displayName,
      localPath: localPath ?? this.localPath,
      sha256: sha256,
      sizeBytes: sizeBytes,
      sourceCommit: sourceCommit,
      runtime: runtime,
      artifactType: artifactType,
      revision: revision,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      failureReason: failureReason ?? this.failureReason,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'model_id': modelId,
      'display_name': displayName,
      'local_path': localPath,
      'sha256': sha256,
      'size_bytes': sizeBytes,
      'source_commit': sourceCommit,
      'runtime': runtime,
      'artifact_type': artifactType,
      'revision': revision,
      'status': status.name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'failure_reason': failureReason?.name,
      'error_message': errorMessage,
    };
  }

  static ModelInstallRecord fromJson(Map<String, Object?> json) {
    final failureReason = json['failure_reason'] as String?;
    return ModelInstallRecord(
      modelId: json['model_id']! as String,
      displayName: json['display_name']! as String,
      localPath: json['local_path'] as String?,
      sha256: json['sha256']! as String,
      sizeBytes: json['size_bytes']! as int,
      sourceCommit: json['source_commit']! as String,
      runtime: json['runtime'] as String? ?? 'litert_lm',
      artifactType: json['artifact_type'] as String? ?? 'litertlm_file',
      revision: json['revision'] as String? ?? json['source_commit']! as String,
      status: ModelInstallStatus.values.byName(json['status']! as String),
      createdAt: DateTime.parse(json['created_at']! as String),
      updatedAt: DateTime.parse(json['updated_at']! as String),
      failureReason: _failureReasonFromName(failureReason),
      errorMessage: json['error_message'] as String?,
    );
  }

  static ModelFailureReason? _failureReasonFromName(String? name) {
    if (name == null) {
      return null;
    }
    for (final reason in ModelFailureReason.values) {
      if (reason.name == name) {
        return reason;
      }
    }
    return ModelFailureReason.unknown;
  }
}
