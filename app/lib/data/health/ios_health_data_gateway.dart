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
  Future<bool> requestReadPermissions(Set<HealthMetricType> metricTypes) {
    return _api.requestReadPermissions(_wireNames(metricTypes));
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

  @override
  Future<List<HealthDataSample>> readSamples({
    required Set<HealthMetricType> metricTypes,
    required DateTime start,
    required DateTime end,
  }) async {
    final rawSamples = await _api.readSamples(
      metricTypes: _wireNames(metricTypes),
      startTime: start,
      endTime: end,
    );
    return rawSamples
        .map(_mapNativeSample)
        .whereType<HealthDataSample>()
        .toList(growable: false);
  }

  static List<String> _wireNames(Set<HealthMetricType> metricTypes) {
    return metricTypes.map((type) => type.wireName).toList(growable: false);
  }

  static HealthDataSample? _mapNativeSample(Map<String, Object?> raw) {
    final typeName = raw['type'];
    final unit = raw['unit'];
    final startTimeMillis = raw['start_time_millis'];
    final endTimeMillis = raw['end_time_millis'];
    if (typeName is! String ||
        unit is! String ||
        startTimeMillis is! num ||
        endTimeMillis is! num) {
      return null;
    }

    final type = HealthMetricTypeNames.fromWireName(typeName);
    if (type == null) {
      return null;
    }

    return HealthDataSample(
      type: type,
      numericValue: _asDouble(raw['numeric_value']),
      textValue: raw['text_value'] as String?,
      unit: unit,
      startTime: DateTime.fromMillisecondsSinceEpoch(startTimeMillis.round()),
      endTime: DateTime.fromMillisecondsSinceEpoch(endTimeMillis.round()),
    );
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
