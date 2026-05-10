import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

final class FakeHealthDataGateway implements HealthDataGateway {
  bool available = true;
  bool permissionGranted = true;
  Set<HealthMetricType>? requestedPermissions;
  final List<Set<HealthMetricType>> permissionRequests =
      <Set<HealthMetricType>>[];
  Set<HealthMetricType>? readMetricTypes;
  DateTime? readStart;
  DateTime? readEnd;
  List<HealthDataAggregate>? aggregates;
  List<HealthDataSample> samples = const <HealthDataSample>[];
  Object? readError;
  bool openSettingsCalled = false;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> requestReadPermissions(Set<HealthMetricType> metricTypes) async {
    requestedPermissions = metricTypes;
    permissionRequests.add(metricTypes);
    return permissionGranted;
  }

  @override
  Future<bool> openAppSettings() async {
    openSettingsCalled = true;
    return true;
  }

  @override
  Future<List<HealthDataAggregate>> readAggregates({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  }) async {
    readMetricTypes = metricTypes;
    readStart = start;
    readEnd = end;
    final error = readError;
    if (error != null) {
      throw error;
    }
    final configured = aggregates;
    if (configured != null) {
      return configured
          .where((aggregate) => metricTypes.contains(aggregate.type))
          .toList(growable: false);
    }
    return _aggregateSamples(metricTypes);
  }

  @override
  Future<List<HealthDataSample>> readSamples({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  }) async {
    readMetricTypes = metricTypes;
    readStart = start;
    readEnd = end;
    final error = readError;
    if (error != null) {
      throw error;
    }
    return samples
        .where((sample) => metricTypes.contains(sample.type))
        .toList(growable: false);
  }

  List<HealthDataAggregate> _aggregateSamples(Set<HealthMetricType> types) {
    final result = <HealthDataAggregate>[];
    for (final type in types) {
      final values = samples
          .where((sample) => sample.type == type)
          .map((sample) => sample.numericValue)
          .nonNulls
          .toList(growable: false);
      if (values.isEmpty) {
        continue;
      }
      final unit = samples.firstWhere((sample) => sample.type == type).unit;
      result.add(switch (type) {
        HealthMetricType.heartRate ||
        HealthMetricType.hrv => HealthDataAggregate(
          type: type,
          unit: unit,
          sampleCount: values.length,
          average: _sum(values) / values.length,
          min: _min(values),
          max: _max(values),
        ),
        _ => HealthDataAggregate(
          type: type,
          unit: unit,
          sampleCount: values.length,
          value: _sum(values),
        ),
      });
    }
    return result;
  }

  double _sum(List<double> values) {
    return values.reduce((left, right) => left + right);
  }

  double _min(List<double> values) {
    return values.reduce((left, right) => left < right ? left : right);
  }

  double _max(List<double> values) {
    return values.reduce((left, right) => left > right ? left : right);
  }
}

HealthDataSample healthSample({
  required HealthMetricType type,
  required double numericValue,
  required String unit,
  DateTime? start,
  DateTime? end,
  String? textValue,
}) {
  final sampleStart = start ?? DateTime.utc(2026, 5, 7, 8);
  return HealthDataSample(
    type: type,
    numericValue: numericValue,
    textValue: textValue,
    unit: unit,
    startTime: sampleStart,
    endTime: end ?? sampleStart.add(const Duration(minutes: 5)),
  );
}
