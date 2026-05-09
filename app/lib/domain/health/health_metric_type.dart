enum HealthMetricType { steps, sleepSession, heartRate }

extension HealthMetricTypeNames on HealthMetricType {
  String get wireName {
    return switch (this) {
      HealthMetricType.steps => 'steps',
      HealthMetricType.sleepSession => 'sleepSession',
      HealthMetricType.heartRate => 'heartRate',
    };
  }

  static HealthMetricType? fromWireName(String wireName) {
    for (final type in HealthMetricType.values) {
      if (type.wireName == wireName) {
        return type;
      }
    }
    return null;
  }
}
