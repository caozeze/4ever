enum HealthMetricType {
  steps,
  sleepSession,
  workoutSession,
  activeEnergy,
  basalEnergy,
  exerciseTime,
  standTime,
  distanceWalkingRunning,
  flightsClimbed,
  heartRate,
  restingHeartRate,
  walkingHeartRateAverage,
  hrv,
  weight,
  mindfulMinutes,
}

extension HealthMetricTypeNames on HealthMetricType {
  String get wireName {
    return switch (this) {
      HealthMetricType.steps => 'steps',
      HealthMetricType.sleepSession => 'sleepSession',
      HealthMetricType.workoutSession => 'workoutSession',
      HealthMetricType.basalEnergy => 'basalEnergy',
      HealthMetricType.exerciseTime => 'exerciseTime',
      HealthMetricType.standTime => 'standTime',
      HealthMetricType.distanceWalkingRunning => 'distanceWalkingRunning',
      HealthMetricType.flightsClimbed => 'flightsClimbed',
      HealthMetricType.heartRate => 'heartRate',
      HealthMetricType.restingHeartRate => 'restingHeartRate',
      HealthMetricType.walkingHeartRateAverage => 'walkingHeartRateAverage',
      HealthMetricType.hrv => 'hrv',
      HealthMetricType.weight => 'weight',
      HealthMetricType.mindfulMinutes => 'mindfulMinutes',
      HealthMetricType.activeEnergy => 'activeEnergy',
    };
  }

  String get displayName {
    return switch (this) {
      HealthMetricType.steps => 'Steps',
      HealthMetricType.sleepSession => 'Sleep',
      HealthMetricType.workoutSession => 'Workouts',
      HealthMetricType.activeEnergy => 'Active Energy',
      HealthMetricType.basalEnergy => 'Basal Energy',
      HealthMetricType.exerciseTime => 'Exercise Time',
      HealthMetricType.standTime => 'Stand Time',
      HealthMetricType.distanceWalkingRunning => 'Walking + Running Distance',
      HealthMetricType.flightsClimbed => 'Flights Climbed',
      HealthMetricType.heartRate => 'Heart Rate',
      HealthMetricType.restingHeartRate => 'Resting Heart Rate',
      HealthMetricType.walkingHeartRateAverage => 'Walking Heart Rate Average',
      HealthMetricType.hrv => 'HRV',
      HealthMetricType.weight => 'Weight',
      HealthMetricType.mindfulMinutes => 'Mindful Minutes',
    };
  }

  Duration get verificationLookback {
    return switch (this) {
      HealthMetricType.sleepSession => const Duration(days: 14),
      HealthMetricType.weight => const Duration(days: 365 * 30),
      _ => const Duration(days: 7),
    };
  }

  String get verificationWindow {
    return switch (this) {
      HealthMetricType.sleepSession => 'last14d',
      HealthMetricType.weight => 'all_history',
      _ => 'last7d',
    };
  }

  bool get isAverageMetric {
    return switch (this) {
      HealthMetricType.heartRate ||
      HealthMetricType.restingHeartRate ||
      HealthMetricType.walkingHeartRateAverage ||
      HealthMetricType.hrv => true,
      _ => false,
    };
  }

  bool get isRoundedCountMetric {
    return switch (this) {
      HealthMetricType.steps || HealthMetricType.flightsClimbed => true,
      _ => false,
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
