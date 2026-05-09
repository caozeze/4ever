import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

final class FakeHealthDataGateway implements HealthDataGateway {
  bool available = true;
  bool permissionGranted = true;
  Set<HealthMetricType>? requestedPermissions;
  Set<HealthMetricType>? readMetricTypes;
  DateTime? readStart;
  DateTime? readEnd;
  List<HealthDataSample> samples = const <HealthDataSample>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> requestReadPermissions(Set<HealthMetricType> metricTypes) async {
    requestedPermissions = metricTypes;
    return permissionGranted;
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
    return samples
        .where((sample) => metricTypes.contains(sample.type))
        .toList(growable: false);
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
