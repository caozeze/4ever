import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

final class FakeHealthDataGateway implements HealthDataGateway {
  bool available = true;
  bool permissionGranted = true;
  Set<HealthMetricType>? requestedPermissions;
  final List<Set<HealthMetricType>> permissionRequests =
      <Set<HealthMetricType>>[];
  final List<Set<HealthMetricType>> aggregateRequests =
      <Set<HealthMetricType>>[];
  final List<DateTime> aggregateStarts = <DateTime>[];
  final List<DateTime> aggregateEnds = <DateTime>[];
  final List<String> aggregateReadModes = <String>[];
  Set<HealthMetricType>? readMetricTypes;
  DateTime? readStart;
  DateTime? readEnd;
  List<HealthDataAggregate>? aggregates;
  Object? readError;
  bool openSettingsCalled = false;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> requestAllReadPermissions() async {
    final metricTypes = HealthMetricType.values.toSet();
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
    String readMode = 'aggregate',
  }) async {
    aggregateRequests.add(metricTypes);
    aggregateStarts.add(start);
    aggregateEnds.add(end);
    aggregateReadModes.add(readMode);
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
