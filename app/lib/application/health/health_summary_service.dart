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
  static const String reasonPermissionDenied = 'permission_denied';
  static const String reasonNoMatchingSamples = 'no_matching_samples';
  static const String reasonPermissionOrNoData = 'permission_or_no_data';
  static const String reasonReadFailed = 'read_failed';

  static const String periodToday = 'today';
  static const String periodLast24h = 'last24h';
  static const String metricSteps = 'steps';
  static const String metricSleepSession = 'sleepSession';
  static const String metricHeartRate = 'heartRate';
  static const String metricHrv = 'hrv';
  static const String metricActiveEnergy = 'activeEnergy';

  static const Set<String> supportedPeriods = <String>{'today', 'last24h'};
  static const Set<HealthMetricType> supportedMetrics = <HealthMetricType>{
    HealthMetricType.steps,
    HealthMetricType.sleepSession,
    HealthMetricType.heartRate,
    HealthMetricType.hrv,
    HealthMetricType.activeEnergy,
  };

  final HealthDataGateway _gateway;
  final AgentTraceSink _traceSink;

  Future<Map<String, Object?>> getHealthSummary({
    required String period,
    required List<String> metrics,
    DateTime? now,
    bool requestPermission = true,
  }) async {
    final metricTypes = _parseMetrics(metrics);
    if (!supportedPeriods.contains(period) || metricTypes == null) {
      final result = <String, Object?>{
        'status': statusInvalidRequest,
        'reason': reasonInvalidRequest,
        'period': period,
        'metrics': <String, Object?>{},
      };
      _recordFinish(result, metrics);
      return result;
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
      final result = <String, Object?>{
        'status': statusUnavailable,
        'reason': reasonHealthKitUnavailable,
        'period': period,
        'metrics': <String, Object?>{},
      };
      _recordFinish(result, metricNames);
      return result;
    }

    if (requestPermission) {
      final granted = await _gateway.requestReadPermissions(metricTypes);
      if (!granted) {
        final result = <String, Object?>{
          'status': statusPermissionDenied,
          'reason': reasonPermissionDenied,
          'period': period,
          'metrics': <String, Object?>{},
        };
        _recordFinish(result, metricNames);
        return result;
      }
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
      final result = <String, Object?>{
        'status': statusUnavailable,
        'reason': reasonReadFailed,
        'period': period,
        'metrics': <String, Object?>{},
      };
      _recordFinish(result, metricNames);
      return result;
    }
    final metricsJson = <String, Object?>{};
    for (final aggregate in aggregates) {
      if (metricTypes.contains(aggregate.type)) {
        final value = _aggregateJson(aggregate);
        if (value != null) {
          metricsJson[aggregate.type.wireName] = value;
        }
      }
    }

    final status = metricsJson.isEmpty ? statusNoData : statusOk;
    final result = <String, Object?>{
      'status': status,
      if (status == statusNoData) 'reason': reasonPermissionOrNoData,
      'period': period,
      'metrics': metricsJson,
    };
    _recordFinish(result, metricNames);
    return result;
  }

  Set<HealthMetricType>? _parseMetrics(List<String> metrics) {
    if (metrics.isEmpty) {
      return null;
    }
    final parsed = <HealthMetricType>{};
    for (final metric in metrics) {
      final type = HealthMetricTypeNames.fromWireName(metric);
      if (type == null || !supportedMetrics.contains(type)) {
        return null;
      }
      parsed.add(type);
    }
    return parsed;
  }

  ({DateTime start, DateTime end}) _rangeFor({
    required String period,
    required DateTime now,
  }) {
    return switch (period) {
      'today' => (start: DateTime(now.year, now.month, now.day), end: now),
      'last24h' => (start: now.subtract(const Duration(hours: 24)), end: now),
      _ => throw ArgumentError.value(period, 'period'),
    };
  }

  Map<String, Object?>? _aggregateJson(HealthDataAggregate aggregate) {
    if (aggregate.sampleCount <= 0) {
      return null;
    }

    return switch (aggregate.type) {
      HealthMetricType.steps => <String, Object?>{
        if (aggregate.value != null) 'value': aggregate.value!.round(),
        'unit': aggregate.unit,
        'sample_count': aggregate.sampleCount,
      },
      HealthMetricType.sleepSession => <String, Object?>{
        if (aggregate.value != null) 'value': _roundOne(aggregate.value!),
        'unit': aggregate.unit,
        'sample_count': aggregate.sampleCount,
      },
      HealthMetricType.heartRate => <String, Object?>{
        if (aggregate.average != null) 'average': _roundOne(aggregate.average!),
        if (aggregate.min != null) 'min': _roundOne(aggregate.min!),
        if (aggregate.max != null) 'max': _roundOne(aggregate.max!),
        'unit': aggregate.unit,
        'sample_count': aggregate.sampleCount,
      },
      HealthMetricType.hrv => <String, Object?>{
        if (aggregate.average != null) 'average': _roundOne(aggregate.average!),
        if (aggregate.min != null) 'min': _roundOne(aggregate.min!),
        if (aggregate.max != null) 'max': _roundOne(aggregate.max!),
        'unit': aggregate.unit,
        'sample_count': aggregate.sampleCount,
      },
      HealthMetricType.activeEnergy => <String, Object?>{
        if (aggregate.value != null) 'value': _roundOne(aggregate.value!),
        'unit': aggregate.unit,
        'sample_count': aggregate.sampleCount,
      },
    };
  }

  double _roundOne(double value) {
    return double.parse(value.toStringAsFixed(1));
  }

  List<String> _wireNames(Set<HealthMetricType> metricTypes) {
    return metricTypes.map((metricType) => metricType.wireName).toList();
  }

  void _recordFinish(Map<String, Object?> result, List<String> metricNames) {
    _traceSink.record(
      AgentTraceEvent(
        event: 'health_summary_read_finish',
        metricNames: metricNames,
        period: result['period'] as String?,
        status: result['status'] as String?,
        sampleCount: _sampleCount(result),
        phase: 'health_summary',
      ),
    );
  }

  int? _sampleCount(Map<String, Object?> result) {
    final metrics = result['metrics'];
    if (metrics is! Map) {
      return null;
    }
    var count = 0;
    for (final value in metrics.values) {
      if (value is Map && value['sample_count'] is num) {
        count += (value['sample_count'] as num).round();
      }
    }
    return count == 0 ? null : count;
  }
}
