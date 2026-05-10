import '../../application/health/health_data_gateway.dart';
import '../../core/native/ios_health_data_api.dart';
import '../../domain/health/health_metric_type.dart';

final class IosHealthDataGateway implements HealthDataGateway {
  const IosHealthDataGateway(this._api);

  final IosHealthDataApi _api;

  @override
  Future<bool> isAvailable() {
    return _api.isAvailable();
  }

  @override
  Future<bool> requestAllReadPermissions() {
    return _api.requestAllReadPermissions();
  }

  @override
  Future<bool> openAppSettings() {
    return _api.openAppSettings();
  }

  @override
  Future<List<HealthDataAggregate>> readAggregates({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  }) async {
    final rawAggregates = await _api.readAggregates(
      metricTypes: _wireNames(metricTypes),
      startTime: start,
      endTime: end,
    );
    return rawAggregates
        .map(_mapNativeAggregate)
        .whereType<HealthDataAggregate>()
        .toList(growable: false);
  }

  static List<String> _wireNames(Set<HealthMetricType> metricTypes) {
    return metricTypes.map((type) => type.wireName).toList(growable: false);
  }

  static HealthDataAggregate? _mapNativeAggregate(Map<String, Object?> raw) {
    final typeName = raw['type'];
    final unit = raw['unit'];
    final sampleCount = raw['sample_count'];
    if (typeName is! String || unit is! String || sampleCount is! num) {
      return null;
    }

    final type = HealthMetricTypeNames.fromWireName(typeName);
    if (type == null) {
      return null;
    }

    return HealthDataAggregate(
      type: type,
      unit: unit,
      sampleCount: sampleCount.round(),
      value: _asDouble(raw['value']),
      average: _asDouble(raw['average']),
      min: _asDouble(raw['min']),
      max: _asDouble(raw['max']),
    );
  }

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}
