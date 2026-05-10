import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_local/application/health/health_data_gateway.dart';
import 'package:gemma_local/application/health/health_summary_service.dart';
import 'package:gemma_local/domain/health/health_metric_type.dart';

import 'agent_trace_test_support.dart';
import 'health/health_test_fakes.dart';

void main() {
  test('summarizes active energy for today in kcal', () async {
    final gateway = FakeHealthDataGateway()
      ..aggregates = const <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.activeEnergy,
          unit: 'kcal',
          sampleCount: 2,
          value: 320.5,
        ),
      ];
    final traceSink = RecordingAgentTraceSink();
    final service = HealthSummaryService(
      gateway: gateway,
      traceSink: traceSink,
    );

    final result = await service.getHealthSummary(
      period: 'today',
      metrics: <String>['activeEnergy'],
      now: DateTime(2026, 5, 10, 15, 30),
    );

    expect(result['status'], HealthSummaryService.statusOk);
    expect(result['period'], HealthSummaryService.periodToday);
    expect(result['requested_metrics'], <String>['activeEnergy']);
    expect(result['start_time'], DateTime(2026, 5, 10).toIso8601String());
    expect(result['end_time'], DateTime(2026, 5, 10, 15, 30).toIso8601String());
    expect(gateway.requestedPermissions, isNull);
    expect(gateway.readMetricTypes, <HealthMetricType>{
      HealthMetricType.activeEnergy,
    });
    expect(gateway.readStart, DateTime(2026, 5, 10));
    expect(gateway.readEnd, DateTime(2026, 5, 10, 15, 30));
    final metrics = result['metrics']! as Map<String, Object?>;
    expect(metrics['activeEnergy'], <String, Object?>{
      'value': 320.5,
      'unit': 'kcal',
      'sample_count': 2,
    });
    expect(traceSink.eventNames, <String>[
      'health_summary_read_start',
      'health_summary_read_finish',
    ]);
    final finishEvent = traceSink.events.last;
    expect(finishEvent.status, HealthSummaryService.statusOk);
    expect(finishEvent.metricNames, <String>['activeEnergy']);
    expect(finishEvent.sampleCount, 2);
  });

  test('returns no_data when HealthKit has no requested aggregate', () async {
    final traceSink = RecordingAgentTraceSink();
    final service = HealthSummaryService(
      gateway: FakeHealthDataGateway(),
      traceSink: traceSink,
    );

    final result = await service.getHealthSummary(
      period: 'last24h',
      metrics: <String>['activeEnergy'],
      now: DateTime(2026, 5, 10, 15, 30),
    );

    expect(result['status'], HealthSummaryService.statusNoData);
    expect(
      result['reason'],
      HealthSummaryService.reasonPermissionOrNoVisibleData,
    );
    expect(result['requested_metrics'], <String>['activeEnergy']);
    expect(result['metrics'], isEmpty);
    expect(traceSink.events.last.status, HealthSummaryService.statusNoData);
  });

  test('summarizes latest heart rate with sample timestamp', () async {
    final gateway = FakeHealthDataGateway()
      ..aggregates = <HealthDataAggregate>[
        HealthDataAggregate(
          type: HealthMetricType.heartRate,
          unit: 'bpm',
          sampleCount: 1,
          value: 72,
          sampleEndTime: DateTime(2026, 5, 10, 15, 25),
        ),
      ];
    final service = HealthSummaryService(gateway: gateway);

    final result = await service.getHealthSummary(
      period: HealthSummaryService.periodLatest,
      metrics: <String>['heartRate'],
      now: DateTime(2026, 5, 10, 15, 30),
    );

    expect(result['status'], HealthSummaryService.statusOk);
    expect(gateway.aggregateReadModes, <String>['latest']);
    expect(gateway.readStart, DateTime.fromMillisecondsSinceEpoch(0));
    expect(gateway.readEnd, DateTime(2026, 5, 10, 15, 30));
    final metrics = result['metrics']! as Map<String, Object?>;
    expect(metrics['heartRate'], <String, Object?>{
      'value': 72.0,
      'unit': 'bpm',
      'sample_count': 1,
      'as_of': DateTime(2026, 5, 10, 15, 25).toIso8601String(),
      'sample_end_time': DateTime(2026, 5, 10, 15, 25).toIso8601String(),
    });
  });

  test(
    'summarizes partial multi-metric result and reports missing metrics',
    () async {
      final gateway = FakeHealthDataGateway()
        ..aggregates = const <HealthDataAggregate>[
          HealthDataAggregate(
            type: HealthMetricType.steps,
            unit: 'count',
            sampleCount: 1,
            value: 2400,
          ),
        ];
      final service = HealthSummaryService(gateway: gateway);

      final result = await service.getHealthSummary(
        period: HealthSummaryService.periodToday,
        metrics: <String>['steps', 'activeEnergy'],
        now: DateTime(2026, 5, 10, 15, 30),
      );

      expect(result['status'], HealthSummaryService.statusOk);
      expect(result['missing_metrics'], <String>['activeEnergy']);
      final metrics = result['metrics']! as Map<String, Object?>;
      expect(metrics.keys, <String>['steps']);
    },
  );

  test('returns unavailable when HealthKit is not available', () async {
    final gateway = FakeHealthDataGateway()..available = false;
    final traceSink = RecordingAgentTraceSink();
    final service = HealthSummaryService(
      gateway: gateway,
      traceSink: traceSink,
    );

    final result = await service.getHealthSummary(
      period: 'today',
      metrics: <String>['steps'],
      now: DateTime(2026, 5, 10, 15, 30),
    );

    expect(result['status'], HealthSummaryService.statusUnavailable);
    expect(result['reason'], HealthSummaryService.reasonHealthKitUnavailable);
    expect(
      traceSink.events.last.status,
      HealthSummaryService.statusUnavailable,
    );
  });

  test(
    'returns unavailable with read_failed reason when sample read throws',
    () async {
      final gateway = FakeHealthDataGateway()..readError = StateError('boom');
      final traceSink = RecordingAgentTraceSink();
      final service = HealthSummaryService(
        gateway: gateway,
        traceSink: traceSink,
      );

      final result = await service.getHealthSummary(
        period: 'today',
        metrics: <String>['steps'],
        now: DateTime(2026, 5, 10, 15, 30),
      );

      expect(result['status'], HealthSummaryService.statusUnavailable);
      expect(result['reason'], HealthSummaryService.reasonReadFailed);
      expect(
        traceSink.events.last.status,
        HealthSummaryService.statusUnavailable,
      );
    },
  );
}
