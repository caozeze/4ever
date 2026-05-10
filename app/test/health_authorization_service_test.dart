import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/health/health_authorization_service.dart';
import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/application/health/health_summary_service.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

import 'health/health_test_fakes.dart';

void main() {
  test('requests all permissions once and verifies readable metrics', () async {
    final gateway = FakeHealthDataGateway()
      ..aggregates = const <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.steps,
          unit: 'count',
          sampleCount: 1,
          value: 1234,
        ),
      ];
    final service = HealthAuthorizationService(gateway: gateway);

    final result = await service.requestDefaultReadPermissions();

    expect(result.status, HealthAuthorizationService.statusCompleted);
    expect(gateway.permissionRequests, <Set<HealthMetricType>>[
      HealthAuthorizationService.defaultMetrics.toSet(),
    ]);
    expect(
      gateway.aggregateRequests.expand((request) => request).toSet(),
      HealthAuthorizationService.defaultMetrics.toSet(),
    );
    expect(gateway.aggregateStarts.any((start) => start.year <= 2000), isTrue);
    final steps = result.metrics.singleWhere(
      (metric) => metric.metric == HealthMetricType.steps,
    );
    expect(steps.status, HealthAuthorizationService.statusReadable);
    expect(steps.summary?['value'], 1234);
    final sleep = result.metrics.singleWhere(
      (metric) => metric.metric == HealthMetricType.sleepSession,
    );
    expect(sleep.status, HealthAuthorizationService.statusNoVisibleData);
    expect(
      sleep.reason,
      HealthAuthorizationService.reasonPermissionOrNoVisibleData,
    );
    expect(HealthMetricType.sleepSession.verificationWindow, 'last14d');
  });

  test('health metric metadata lives on HealthMetricType', () {
    expect(HealthMetricType.steps.displayName, 'Steps');
    expect(HealthMetricType.steps.wireName, 'steps');
    expect(HealthMetricType.steps.verificationWindow, 'last7d');
    expect(HealthMetricType.steps.isRoundedCountMetric, isTrue);
    expect(HealthMetricType.heartRate.isAverageMetric, isTrue);
    expect(HealthMetricType.weight.verificationWindow, 'all_history');
  });

  test('opens app settings through gateway', () async {
    final gateway = FakeHealthDataGateway();
    final service = HealthAuthorizationService(gateway: gateway);

    expect(await service.openAppSettings(), isTrue);
    expect(gateway.openSettingsCalled, isTrue);
  });

  test(
    'reports request failure for every metric when permission request fails',
    () async {
      final gateway = FakeHealthDataGateway()..permissionGranted = false;
      final service = HealthAuthorizationService(gateway: gateway);

      final result = await service.requestDefaultReadPermissions();

      expect(result.status, HealthSummaryService.statusPermissionDenied);
      expect(gateway.permissionRequests, <Set<HealthMetricType>>[
        HealthAuthorizationService.defaultMetrics.toSet(),
      ]);
      expect(gateway.aggregateRequests, isEmpty);
      expect(result.metrics.map((metric) => metric.status).toSet(), <String>{
        HealthSummaryService.statusPermissionDenied,
      });
    },
  );

  test(
    'does not report authorization success when HealthKit is unavailable',
    () async {
      final gateway = FakeHealthDataGateway()..available = false;
      final service = HealthAuthorizationService(gateway: gateway);

      final result = await service.requestDefaultReadPermissions();

      expect(result.status, HealthSummaryService.statusUnavailable);
      expect(result.metrics.map((metric) => metric.status).toSet(), <String>{
        HealthSummaryService.statusUnavailable,
      });
    },
  );
}
