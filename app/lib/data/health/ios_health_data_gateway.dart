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

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}
