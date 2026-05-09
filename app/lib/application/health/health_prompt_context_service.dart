import '../../domain/health/health_metric_type.dart';
import 'health_data_gateway.dart';

final class LocalHealthPromptContext {
  const LocalHealthPromptContext._(this.promptText, {required this.hasData});

  factory LocalHealthPromptContext.noData([String? reason]) {
    final suffix = reason == null ? '' : ' ($reason)';
    return LocalHealthPromptContext._(
      'No Apple Health aggregate is available for the last 24 hours$suffix.',
      hasData: false,
    );
  }

  factory LocalHealthPromptContext.fromSamples(List<HealthDataSample> samples) {
    final summary = _HealthAggregateSummary(samples);
    if (!summary.hasData) {
      return LocalHealthPromptContext.noData();
    }
    return LocalHealthPromptContext._(summary.toPromptText(), hasData: true);
  }

  final String promptText;
  final bool hasData;
}

abstract interface class HealthPromptContextService {
  Future<LocalHealthPromptContext> buildForChat({
    DateTime? now,
    Duration lookback = const Duration(hours: 24),
  });
}

final class DefaultHealthPromptContextService
    implements HealthPromptContextService {
  const DefaultHealthPromptContextService({required HealthDataGateway gateway})
    : _gateway = gateway;

  static const Set<HealthMetricType> chatMetricTypes = <HealthMetricType>{
    HealthMetricType.steps,
    HealthMetricType.sleepSession,
    HealthMetricType.heartRate,
  };

  final HealthDataGateway _gateway;

  @override
  Future<LocalHealthPromptContext> buildForChat({
    DateTime? now,
    Duration lookback = const Duration(hours: 24),
  }) async {
    final end = now ?? DateTime.now();
    final start = end.subtract(lookback);
    if (!await _gateway.isAvailable()) {
      return LocalHealthPromptContext.noData('HealthKit unavailable');
    }

    final granted = await _gateway.requestReadPermissions(chatMetricTypes);
    if (!granted) {
      return LocalHealthPromptContext.noData('permission not granted');
    }

    final samples = await _gateway.readSamples(
      metricTypes: chatMetricTypes,
      start: start,
      end: end,
    );
    return LocalHealthPromptContext.fromSamples(samples);
  }
}

final class _HealthAggregateSummary {
  _HealthAggregateSummary(this.samples);

  final List<HealthDataSample> samples;

  bool get hasData {
    return _sum(HealthMetricType.steps) != null ||
        _sum(HealthMetricType.sleepSession) != null ||
        _average(HealthMetricType.heartRate) != null;
  }

  String toPromptText() {
    final steps = _sum(HealthMetricType.steps)?.round();
    final sleepHours = _sum(HealthMetricType.sleepSession);
    final heartRateAvg = _average(HealthMetricType.heartRate);
    final heartRateMin = _min(HealthMetricType.heartRate);
    final heartRateMax = _max(HealthMetricType.heartRate);

    return <String>[
      'Apple Health aggregate for the last 24 hours:',
      if (steps != null) '- steps: $steps',
      if (sleepHours != null) '- sleep: ${_formatOneDecimal(sleepHours)} hours',
      if (heartRateAvg != null)
        '- heart rate average: ${_formatOneDecimal(heartRateAvg)} bpm',
      if (heartRateMin != null && heartRateMax != null)
        '- heart rate range: ${_formatOneDecimal(heartRateMin)}-${_formatOneDecimal(heartRateMax)} bpm',
    ].join('\n');
  }

  double? _sum(HealthMetricType type) {
    final values = _values(type);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((left, right) => left + right);
  }

  double? _average(HealthMetricType type) {
    final values = _values(type);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((left, right) => left + right) / values.length;
  }

  double? _min(HealthMetricType type) {
    final values = _values(type);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((left, right) => left < right ? left : right);
  }

  double? _max(HealthMetricType type) {
    final values = _values(type);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((left, right) => left > right ? left : right);
  }

  List<double> _values(HealthMetricType type) {
    return samples
        .where((sample) => sample.type == type)
        .map((sample) => sample.numericValue)
        .nonNulls
        .toList(growable: false);
  }

  static String _formatOneDecimal(double value) {
    final rounded = value.toStringAsFixed(1);
    return rounded.endsWith('.0')
        ? rounded.substring(0, rounded.length - 2)
        : rounded;
  }
}
