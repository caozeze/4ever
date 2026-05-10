import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/health/health_authorization_service.dart';
import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/application/health/health_summary_service.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

import 'health/health_test_fakes.dart';

void main() {
  test('requests each permission and verifies readable metrics', () async {
    final gateway = FakeHealthDataGateway()
      ..aggregates = const <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.steps,
          unit: 'count',
          sampleCount: 1,
          value: 1234,
        ),
      ];
    final service = HealthAuthorizationService(
      gateway: gateway,
      healthSummaryService: HealthSummaryService(gateway: gateway),
    );

    final result = await service.requestDefaultReadPermissions();

    expect(result.status, HealthAuthorizationResult.statusCompleted);
    expect(gateway.permissionRequests, <Set<HealthMetricType>>[
      <HealthMetricType>{HealthMetricType.steps},
      <HealthMetricType>{HealthMetricType.sleepSession},
      <HealthMetricType>{HealthMetricType.heartRate},
      <HealthMetricType>{HealthMetricType.hrv},
      <HealthMetricType>{HealthMetricType.activeEnergy},
    ]);
    final steps = result.metrics.singleWhere(
      (metric) => metric.metric == HealthMetricType.steps,
    );
    expect(steps.status, HealthMetricAuthorizationResult.statusReadable);
    expect(steps.summary?['value'], 1234);
    final sleep = result.metrics.singleWhere(
      (metric) => metric.metric == HealthMetricType.sleepSession,
    );
    expect(sleep.status, HealthMetricAuthorizationResult.statusNoVisibleData);
  });

  test('can request and verify one metric', () async {
    final gateway = FakeHealthDataGateway()
      ..aggregates = const <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.steps,
          unit: 'count',
          sampleCount: 1,
          value: 1234,
        ),
      ];
    final service = HealthAuthorizationService(
      gateway: gateway,
      healthSummaryService: HealthSummaryService(gateway: gateway),
    );

    final result = await service.requestMetricReadPermission(
      HealthMetricType.steps,
    );

    expect(gateway.permissionRequests, <Set<HealthMetricType>>[
      <HealthMetricType>{HealthMetricType.steps},
    ]);
    expect(result.status, HealthMetricAuthorizationResult.statusReadable);
    expect(result.summary?['value'], 1234);
  });

  test('opens app settings through gateway', () async {
    final gateway = FakeHealthDataGateway();
    final service = HealthAuthorizationService(
      gateway: gateway,
      healthSummaryService: HealthSummaryService(gateway: gateway),
    );

    expect(await service.openAppSettings(), isTrue);
    expect(gateway.openSettingsCalled, isTrue);
  });

  test(
    'does not report authorization success when HealthKit is unavailable',
    () async {
      final gateway = FakeHealthDataGateway()..available = false;
      final service = HealthAuthorizationService(
        gateway: gateway,
        healthSummaryService: HealthSummaryService(gateway: gateway),
      );

      final result = await service.requestDefaultReadPermissions();

      expect(result.status, HealthSummaryService.statusUnavailable);
      expect(result.metrics.map((metric) => metric.status).toSet(), <String>{
        HealthSummaryService.statusUnavailable,
      });
    },
  );
}
