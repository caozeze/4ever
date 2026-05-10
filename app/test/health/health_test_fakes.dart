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
    return const <HealthDataAggregate>[];
  }
}
