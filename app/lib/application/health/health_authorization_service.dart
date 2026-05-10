import '../../domain/health/health_metric_type.dart';
import 'health_data_gateway.dart';
import 'health_summary_service.dart';

class HealthAuthorizationService {
  const HealthAuthorizationService({
    required HealthDataGateway gateway,
    required HealthSummaryService healthSummaryService,
  }) : _gateway = gateway,
       _healthSummaryService = healthSummaryService;

  final HealthDataGateway _gateway;
  final HealthSummaryService _healthSummaryService;

  static const List<HealthMetricType> defaultMetrics = <HealthMetricType>[
    HealthMetricType.steps,
    HealthMetricType.sleepSession,
    HealthMetricType.heartRate,
    HealthMetricType.hrv,
    HealthMetricType.activeEnergy,
  ];

  Future<HealthAuthorizationResult> requestDefaultReadPermissions() async {
    final results = <HealthMetricAuthorizationResult>[];
    for (final metric in defaultMetrics) {
      results.add(await requestMetricReadPermission(metric));
    }
    final status =
        results.every(
          (result) => result.status == HealthSummaryService.statusUnavailable,
        )
        ? HealthSummaryService.statusUnavailable
        : HealthAuthorizationResult.statusCompleted;
    return HealthAuthorizationResult(status: status, metrics: results);
  }

  Future<HealthMetricAuthorizationResult> requestMetricReadPermission(
    HealthMetricType metric,
  ) async {
    if (!await _gateway.isAvailable()) {
      return HealthMetricAuthorizationResult(
        metric: metric,
        status: HealthSummaryService.statusUnavailable,
      );
    }
    final completed = await _gateway.requestReadPermissions(<HealthMetricType>{
      metric,
    });
    if (!completed) {
      return HealthMetricAuthorizationResult(
        metric: metric,
        status: HealthSummaryService.statusPermissionDenied,
      );
    }
    final summary = await _healthSummaryService.getHealthSummary(
      period: _verificationPeriod(metric),
      metrics: <String>[metric.wireName],
      requestPermission: false,
    );
    return _metricResult(metric, summary);
  }

  Future<bool> openAppSettings() {
    return _gateway.openAppSettings();
  }

  String _verificationPeriod(HealthMetricType metric) {
    return metric == HealthMetricType.sleepSession
        ? HealthSummaryService.periodLast24h
        : HealthSummaryService.periodToday;
  }

  HealthMetricAuthorizationResult _metricResult(
    HealthMetricType metric,
    Map<String, Object?> summary,
  ) {
    final metrics = summary['metrics'];
    final metricSummary = metrics is Map ? metrics[metric.wireName] : null;
    if (metricSummary is Map) {
      return HealthMetricAuthorizationResult(
        metric: metric,
        status: HealthMetricAuthorizationResult.statusReadable,
        summary: Map<String, Object?>.from(metricSummary),
      );
    }
    final status = summary['status'];
    return HealthMetricAuthorizationResult(
      metric: metric,
      status: status == HealthSummaryService.statusUnavailable
          ? HealthSummaryService.statusUnavailable
          : HealthMetricAuthorizationResult.statusNoVisibleData,
    );
  }
}

final class HealthAuthorizationResult {
  const HealthAuthorizationResult({
    required this.status,
    required this.metrics,
  });

  static const String statusCompleted = 'authorization_request_completed';

  final String status;
  final List<HealthMetricAuthorizationResult> metrics;
}

final class HealthMetricAuthorizationResult {
  const HealthMetricAuthorizationResult({
    required this.metric,
    required this.status,
    this.summary,
  });

  static const String statusReadable = 'readable';
  static const String statusNoVisibleData = 'no_visible_data';

  final HealthMetricType metric;
  final String status;
  final Map<String, Object?>? summary;
}
