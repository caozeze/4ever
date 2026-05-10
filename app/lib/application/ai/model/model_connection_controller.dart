import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../domain/ai/model_failure_reason.dart';
import '../../../domain/ai/model_install_progress.dart';
import '../../../domain/ai/model_install_status.dart';
import '../demo_chat_controller.dart';

final class ModelConnectionSnapshot {
  const ModelConnectionSnapshot({
    required this.status,
    this.message,
    this.failureReason,
  });

  const ModelConnectionSnapshot.initial()
    : status = ModelInstallStatus.notInstalled,
      message = null,
      failureReason = null;

  final ModelInstallStatus status;
  final String? message;
  final ModelFailureReason? failureReason;

  bool get isReady => status == ModelInstallStatus.ready;
  bool get isConnecting =>
      status == ModelInstallStatus.downloading ||
      status == ModelInstallStatus.verifying ||
      status == ModelInstallStatus.installed ||
      status == ModelInstallStatus.loading;
  bool get isFailed => status == ModelInstallStatus.failed;

  ModelConnectionSnapshot copyWith({
    ModelInstallStatus? status,
    String? message,
    ModelFailureReason? failureReason,
  }) {
    return ModelConnectionSnapshot(
      status: status ?? this.status,
      message: message,
      failureReason: failureReason ?? this.failureReason,
    );
  }
}

final class ModelConnectionController extends ChangeNotifier {
  ModelConnectionController({
    required Future<DemoChatController> Function() loadController,
    Duration connectionTimeout = const Duration(seconds: 90),
  }) : _loadController = loadController,
       _connectionTimeout = connectionTimeout;

  final Future<DemoChatController> Function() _loadController;
  final Duration _connectionTimeout;
  Future<DemoChatController>? _controllerFuture;
  Future<void>? _activeConnection;
  StreamSubscription<ModelInstallProgress>? _activeProgressSubscription;
  Completer<void>? _activeProgressCompletion;
  var _connectionAttempt = 0;
  ModelConnectionSnapshot _snapshot = const ModelConnectionSnapshot.initial();

  ModelConnectionSnapshot get snapshot => _snapshot;

  @override
  void dispose() {
    unawaited(_cancelActiveProgressSubscription());
    super.dispose();
  }

  Future<void> ensureModelReady({bool force = false}) {
    if (_snapshot.isReady && !force) {
      return Future<void>.value();
    }
    final activeConnection = _activeConnection;
    if (activeConnection != null && !force) {
      return activeConnection;
    }
    if (force) {
      _activeConnection = null;
      unawaited(_cancelActiveProgressSubscription());
    }
    final attempt = ++_connectionAttempt;
    final connection = _connect(attempt).timeout(
      _connectionTimeout,
      onTimeout: () {
        if (attempt == _connectionAttempt) {
          _connectionAttempt += 1;
          _controllerFuture = null;
          _activeConnection = null;
          unawaited(_cancelActiveProgressSubscription());
          _setSnapshot(
            const ModelConnectionSnapshot(
              status: ModelInstallStatus.failed,
              message: 'Local Gemma connection timed out. Tap Retry.',
              failureReason: ModelFailureReason.runtimeFailed,
            ),
          );
        }
      },
    );
    _activeConnection = connection;
    return connection.whenComplete(() {
      if (identical(_activeConnection, connection) &&
          attempt == _connectionAttempt) {
        _activeConnection = null;
      }
    });
  }

  Future<void> retry() async {
    if (_snapshot.isReady) {
      await cancelActiveGeneration();
    }
    await ensureModelReady(force: true);
  }

  Future<void> handleLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        await ensureModelReady();
        return;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        return;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        await cancelActiveGeneration();
        return;
    }
  }

  Future<void> cancelActiveGeneration() async {
    final controllerFuture = _controllerFuture;
    if (controllerFuture == null) {
      return;
    }
    final controller = await controllerFuture;
    await controller.cancelActiveGeneration();
  }

  Future<DemoChatController> _controller() {
    return _controllerFuture ??= _loadController();
  }

  Future<void> _connect(int attempt) async {
    _setSnapshot(
      const ModelConnectionSnapshot(
        status: ModelInstallStatus.notInstalled,
        message: 'Checking local Gemma...',
      ),
    );
    try {
      final controller = await _controller();
      if (attempt != _connectionAttempt) {
        return;
      }
      final streamDone = Completer<void>();
      late final StreamSubscription<ModelInstallProgress> subscription;
      subscription = controller.ensureModelReady().listen(
        (ModelInstallProgress progress) {
          if (attempt != _connectionAttempt) {
            unawaited(subscription.cancel());
            if (!streamDone.isCompleted) {
              streamDone.complete();
            }
            return;
          }
          _setSnapshot(_snapshotFor(progress));
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!streamDone.isCompleted) {
            streamDone.completeError(error, stackTrace);
          }
        },
        onDone: () {
          if (!streamDone.isCompleted) {
            streamDone.complete();
          }
        },
        cancelOnError: true,
      );
      _activeProgressSubscription = subscription;
      _activeProgressCompletion = streamDone;
      try {
        await streamDone.future;
      } finally {
        if (identical(_activeProgressSubscription, subscription)) {
          _activeProgressSubscription = null;
          _activeProgressCompletion = null;
        }
      }
    } on Object catch (error) {
      if (attempt != _connectionAttempt) {
        return;
      }
      _setSnapshot(
        ModelConnectionSnapshot(
          status: ModelInstallStatus.failed,
          message: error.toString(),
          failureReason: ModelFailureReason.runtimeFailed,
        ),
      );
    }
  }

  ModelConnectionSnapshot _snapshotFor(ModelInstallProgress progress) {
    return ModelConnectionSnapshot(
      status: progress.status,
      message: switch (progress.status) {
        ModelInstallStatus.ready => null,
        ModelInstallStatus.failed => progress.message,
        ModelInstallStatus.downloading =>
          progress.message ?? 'Checking local Gemma...',
        ModelInstallStatus.verifying =>
          progress.message ?? 'Checking local Gemma...',
        ModelInstallStatus.installed => 'Loading local Gemma...',
        ModelInstallStatus.loading => 'Loading local Gemma...',
        ModelInstallStatus.notInstalled =>
          progress.message ?? 'Checking local Gemma...',
        ModelInstallStatus.unloaded =>
          progress.message ?? 'Checking local Gemma...',
      },
      failureReason: progress.failureReason,
    );
  }

  void _setSnapshot(ModelConnectionSnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }

  Future<void> _cancelActiveProgressSubscription() async {
    final subscription = _activeProgressSubscription;
    final completion = _activeProgressCompletion;
    _activeProgressSubscription = null;
    _activeProgressCompletion = null;
    await subscription?.cancel();
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
  }
}
