import '../../domain/health/health_metric_type.dart';
import '../observability/agent_trace_sink.dart';
import 'health_data_gateway.dart';

final class HealthSummaryService {
  const HealthSummaryService({
    required HealthDataGateway gateway,
    AgentTraceSink traceSink = const NoopAgentTraceSink(),
  }) : _gateway = gateway,
       _traceSink = traceSink;

  static const String statusOk = 'ok';
  static const String statusNoData = 'no_data';
  static const String statusPermissionDenied = 'permission_denied';
  static const String statusUnavailable = 'unavailable';
  static const String statusInvalidRequest = 'invalid_request';

  static const String reasonInvalidRequest = 'invalid_request';
  static const String reasonHealthKitUnavailable = 'healthkit_unavailable';
  static const String reasonPermissionOrNoVisibleData =
      'permission_or_no_visible_data';
  static const String reasonReadFailed = 'read_failed';

  static const String periodToday = 'today';
  static const String periodLast24h = 'last24h';

  final HealthDataGateway _gateway;
  final AgentTraceSink _traceSink;

  Future<Map<String, Object?>> getHealthSummary({
    required String period,
    required List<String> metrics,
    DateTime? now,
  }) async {
    final metricTypes = _parseMetrics(metrics);
    if (!_isSupportedPeriod(period) || metricTypes == null) {
      return _finish(
        status: statusInvalidRequest,
        reason: reasonInvalidRequest,
        period: period,
        metricNames: metrics,
      );
    }

    final metricNames = _wireNames(metricTypes);
    _traceSink.record(
      AgentTraceEvent(
        event: 'health_summary_read_start',
        metricNames: metricNames,
        period: period,
        phase: 'health_summary',
      ),
    );

    if (!await _gateway.isAvailable()) {
      return _finish(
        status: statusUnavailable,
        reason: reasonHealthKitUnavailable,
        period: period,
        metricNames: metricNames,
      );
    }

    final range = _rangeFor(period: period, now: now ?? DateTime.now());
    final List<HealthDataAggregate> aggregates;
    try {
      aggregates = await _gateway.readAggregates(
        metricTypes: metricTypes,
        start: range.start,
        end: range.end,
      );
    } on Object {
      return _finish(
        status: statusUnavailable,
        reason: reasonReadFailed,
        period: period,
        metricNames: metricNames,
      );
    }

    final metricsJson = <String, Object?>{};
    for (final aggregate in aggregates) {
      final value = _aggregateJson(aggregate);
      if (value != null) {
        metricsJson[aggregate.type.wireName] = value;
      }
    }
    if (metricsJson.isEmpty) {
      return _finish(
        status: statusNoData,
        reason: reasonPermissionOrNoVisibleData,
        period: period,
        metricNames: metricNames,
        requestedMetrics: metricNames,
      );
    }
    return _finish(
      status: statusOk,
      period: period,
      metricNames: metricNames,
      metrics: metricsJson,
    );
  }

  Set<HealthMetricType>? _parseMetrics(List<String> metrics) {
    if (metrics.isEmpty) {
      return null;
    }
    final parsed = <HealthMetricType>{};
    for (final metric in metrics) {
      final type = HealthMetricTypeNames.fromWireName(metric);
      if (type == null) {
        return null;
      }
      parsed.add(type);
    }
    return parsed;
  }

  bool _isSupportedPeriod(String period) {
    return period == periodToday || period == periodLast24h;
  }

  ({DateTime start, DateTime end}) _rangeFor({
    required String period,
    required DateTime now,
  }) {
    return switch (period) {
      periodToday => (start: DateTime(now.year, now.month, now.day), end: now),
      periodLast24h => (
        start: now.subtract(const Duration(hours: 24)),
        end: now,
      ),
      _ => throw ArgumentError.value(period, 'period'),
    };
  }

  Map<String, Object?>? _aggregateJson(HealthDataAggregate aggregate) {
    if (aggregate.sampleCount <= 0) {
      return null;
    }
    final metric = aggregate.type;
    if (metric.isAverageMetric) {
      return <String, Object?>{
        if (aggregate.average != null) 'average': _roundOne(aggregate.average!),
        if (aggregate.min != null) 'min': _roundOne(aggregate.min!),
        if (aggregate.max != null) 'max': _roundOne(aggregate.max!),
        'unit': aggregate.unit,
        'sample_count': aggregate.sampleCount,
      };
    }
    return <String, Object?>{
      if (aggregate.value != null)
        'value': metric.isRoundedCountMetric
            ? aggregate.value!.round()
            : _roundOne(aggregate.value!),
      'unit': aggregate.unit,
      'sample_count': aggregate.sampleCount,
    };
  }

  Map<String, Object?> _finish({
    required String status,
    required String period,
    required List<String> metricNames,
    String? reason,
    Map<String, Object?> metrics = const <String, Object?>{},
    List<String>? requestedMetrics,
  }) {
    final result = <String, Object?>{
      'status': status,
      if (reason case final String reason) 'reason': reason,
      if (requestedMetrics case final List<String> requestedMetrics)
        'requested_metrics': requestedMetrics,
      'period': period,
      'metrics': metrics,
    };
    _traceSink.record(
      AgentTraceEvent(
        event: 'health_summary_read_finish',
        metricNames: metricNames,
        period: period,
        status: status,
        sampleCount: _sampleCount(metrics),
        phase: 'health_summary',
      ),
    );
    return result;
  }

  List<String> _wireNames(Set<HealthMetricType> metricTypes) {
    return metricTypes.map((metricType) => metricType.wireName).toList();
  }

  int? _sampleCount(Map<String, Object?> metrics) {
    var count = 0;
    for (final value in metrics.values) {
      if (value is Map && value['sample_count'] is num) {
        count += (value['sample_count'] as num).round();
      }
    }
    return count == 0 ? null : count;
  }

  double _roundOne(double value) {
    return double.parse(value.toStringAsFixed(1));
  }
}
