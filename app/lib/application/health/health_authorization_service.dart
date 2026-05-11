import '../../domain/health/health_metric_type.dart';
import 'health_data_gateway.dart';
import 'health_summary_service.dart';

class HealthAuthorizationService {
  const HealthAuthorizationService({required HealthDataGateway gateway})
    : _gateway = gateway;

  static const String statusCompleted = 'authorization_request_completed';
  static const String statusReadable = 'readable';
  static const String statusNoVisibleData = 'no_visible_data';
  static const String reasonPermissionOrNoVisibleData =
      'permission_or_no_visible_data';

  static const List<HealthMetricType> defaultMetrics = HealthMetricType.values;

  final HealthDataGateway _gateway;

  Future<HealthAuthorizationResult> requestDefaultReadPermissions() async {
    if (!await _gateway.isAvailable()) {
      return _resultForAll(HealthSummaryService.statusUnavailable);
    }
    if (!await _gateway.requestAllReadPermissions()) {
      return _resultForAll(HealthSummaryService.statusPermissionDenied);
    }

    final visible = await _visibleSummaries(DateTime.now());
    return HealthAuthorizationResult(
      status: statusCompleted,
      metrics: <HealthMetricAuthorizationResult>[
        for (final metric in defaultMetrics)
          HealthMetricAuthorizationResult(
            metric: metric,
            status: visible.containsKey(metric)
                ? statusReadable
                : statusNoVisibleData,
            reason: visible.containsKey(metric)
                ? null
                : reasonPermissionOrNoVisibleData,
            summary: visible[metric],
          ),
      ],
    );
  }

  Future<bool> openAppSettings() => _gateway.openAppSettings();

  Future<Map<HealthMetricType, Map<String, Object?>>> _visibleSummaries(
    DateTime now,
  ) async {
    final visible = <HealthMetricType, Map<String, Object?>>{};
    for (final group in _verificationGroups(now)) {
      final aggregates = await _gateway.readAggregates(
        metricTypes: group.metrics,
        start: group.start,
        end: now,
      );
      for (final aggregate in aggregates) {
        if (aggregate.sampleCount > 0) {
          visible[aggregate.type] = <String, Object?>{
            if (aggregate.value != null) 'value': aggregate.value,
            if (aggregate.average != null) 'average': aggregate.average,
            'unit': aggregate.unit,
            'sample_count': aggregate.sampleCount,
            'window': aggregate.type.verificationWindow,
          };
        }
      }
    }
    return visible;
  }

  List<_VerificationGroup> _verificationGroups(DateTime now) {
    final groups = <String, _VerificationGroup>{};
    for (final metric in defaultMetrics) {
      groups.update(
        metric.verificationWindow,
        (group) => group..metrics.add(metric),
        ifAbsent: () => _VerificationGroup(
          start: now.subtract(metric.verificationLookback),
          metrics: <HealthMetricType>{metric},
        ),
      );
    }
    return groups.values.toList(growable: false);
  }

  HealthAuthorizationResult _resultForAll(String status) {
    return HealthAuthorizationResult(
      status: status,
      metrics: <HealthMetricAuthorizationResult>[
        for (final metric in defaultMetrics)
          HealthMetricAuthorizationResult(metric: metric, status: status),
      ],
    );
  }
}

final class _VerificationGroup {
  _VerificationGroup({required this.start, required this.metrics});

  final DateTime start;
  final Set<HealthMetricType> metrics;
}

final class HealthAuthorizationResult {
  const HealthAuthorizationResult({
    required this.status,
    required this.metrics,
  });

  final String status;
  final List<HealthMetricAuthorizationResult> metrics;
}

final class HealthMetricAuthorizationResult {
  const HealthMetricAuthorizationResult({
    required this.metric,
    required this.status,
    this.summary,
    this.reason,
  });

  final HealthMetricType metric;
  final String status;
  final Map<String, Object?>? summary;
  final String? reason;
}
