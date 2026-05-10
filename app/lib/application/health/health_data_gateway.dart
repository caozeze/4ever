import '../../domain/health/health_metric_type.dart';

final class HealthDataSample {
  const HealthDataSample({
    required this.type,
    required this.unit,
    required this.startTime,
    required this.endTime,
    this.numericValue,
    this.textValue,
  });

  final HealthMetricType type;
  final double? numericValue;
  final String? textValue;
  final String unit;
  final DateTime startTime;
  final DateTime endTime;
}

final class HealthDataAggregate {
  const HealthDataAggregate({
    required this.type,
    required this.unit,
    required this.sampleCount,
    this.value,
    this.average,
    this.min,
    this.max,
  });

  final HealthMetricType type;
  final String unit;
  final int sampleCount;
  final double? value;
  final double? average;
  final double? min;
  final double? max;
}

abstract interface class HealthDataGateway {
  Future<bool> isAvailable();

  Future<bool> requestReadPermissions(Set<HealthMetricType> metricTypes);

  Future<bool> openAppSettings();

  Future<List<HealthDataAggregate>> readAggregates({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  });

  Future<List<HealthDataSample>> readSamples({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  });
}

final class UnavailableHealthDataGateway implements HealthDataGateway {
  const UnavailableHealthDataGateway(this.message);

  final String message;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> requestReadPermissions(Set<HealthMetricType> metricTypes) async {
    return false;
  }

  @override
  Future<bool> openAppSettings() async {
    return false;
  }

  @override
  Future<List<HealthDataAggregate>> readAggregates({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  }) async {
    throw UnsupportedError(message);
  }

  @override
  Future<List<HealthDataSample>> readSamples({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  }) async {
    throw UnsupportedError(message);
  }
}
