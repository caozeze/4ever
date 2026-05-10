import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/health/health_authorization_service.dart';
import '../../core/providers/health_providers.dart';
import '../../domain/health/health_metric_type.dart';
import '../app_navigation_drawer.dart';

class HealthPermissionsPage extends ConsumerStatefulWidget {
  const HealthPermissionsPage({super.key});

  static const String path = '/health-permissions';

  @override
  ConsumerState<HealthPermissionsPage> createState() =>
      _HealthPermissionsPageState();
}

class _HealthPermissionsPageState extends ConsumerState<HealthPermissionsPage> {
  bool _requesting = false;
  final Set<HealthMetricType> _requestingMetrics = <HealthMetricType>{};
  HealthAuthorizationResult? _result;
  Object? _error;

  Future<void> _requestPermissions() async {
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      final service = ref.read(healthAuthorizationServiceProvider);
      final result = await service.requestDefaultReadPermissions();
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
      });
    } finally {
      if (mounted) {
        setState(() {
          _requesting = false;
        });
      }
    }
  }

  Future<void> _requestMetric(HealthMetricType metric) async {
    setState(() {
      _requestingMetrics.add(metric);
      _error = null;
    });
    try {
      final service = ref.read(healthAuthorizationServiceProvider);
      final result = await service.requestMetricReadPermission(metric);
      if (!mounted) {
        return;
      }
      setState(() {
        _result = _mergeMetricResult(result);
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
      });
    } finally {
      if (mounted) {
        setState(() {
          _requestingMetrics.remove(metric);
        });
      }
    }
  }

  Future<void> _openSettings() async {
    await ref.read(healthAuthorizationServiceProvider).openAppSettings();
  }

  HealthAuthorizationResult _mergeMetricResult(
    HealthMetricAuthorizationResult metricResult,
  ) {
    final current = _result;
    final metrics = <HealthMetricAuthorizationResult>[
      if (current != null) ...current.metrics,
    ];
    final index = metrics.indexWhere(
      (result) => result.metric == metricResult.metric,
    );
    if (index >= 0) {
      metrics[index] = metricResult;
    } else {
      metrics.add(metricResult);
    }
    return HealthAuthorizationResult(
      status: HealthAuthorizationResult.statusCompleted,
      metrics: metrics,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Apple Health Access')),
      drawer: const AppNavigationDrawer(
        currentPath: HealthPermissionsPage.path,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          Text('Apple Health Access', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Authorize local Apple Health reads for chat answers. Data stays on this device.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: HealthSummaryMetricLabels.defaultMetrics
                .map(
                  (metric) => Chip(
                    avatar: Icon(_iconFor(metric), size: 18),
                    label: Text(metric.label),
                  ),
                )
                .toList(growable: false),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey<String>('health_authorize_button'),
              onPressed: _requesting ? null : _requestPermissions,
              icon: _requesting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.health_and_safety),
              label: Text(_requesting ? 'Requesting...' : 'Authorize Health'),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey<String>('health_open_settings_button'),
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Open App Settings'),
            ),
          ),
          const SizedBox(height: 20),
          _PermissionStatus(
            result: _result,
            error: _error,
            requestingMetrics: _requestingMetrics,
            onRequestMetric: _requestMetric,
          ),
        ],
      ),
    );
  }

  IconData _iconFor(HealthMetricType metric) {
    return switch (metric) {
      HealthMetricType.steps => Icons.directions_walk,
      HealthMetricType.sleepSession => Icons.bedtime,
      HealthMetricType.heartRate => Icons.monitor_heart,
      HealthMetricType.hrv => Icons.timeline,
      HealthMetricType.activeEnergy => Icons.local_fire_department,
    };
  }
}

class _PermissionStatus extends StatelessWidget {
  const _PermissionStatus({
    required this.result,
    required this.error,
    required this.requestingMetrics,
    required this.onRequestMetric,
  });

  final HealthAuthorizationResult? result;
  final Object? error;
  final Set<HealthMetricType> requestingMetrics;
  final ValueChanged<HealthMetricType> onRequestMetric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null) {
      return Text(
        'Authorization request failed. Check Apple Health availability and app permissions.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final result = this.result;
    if (result == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Tap authorize to show the Apple Health permission sheet when iOS needs confirmation. You can also retry each metric separately.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          for (final metric in HealthSummaryMetricLabels.defaultMetrics)
            _MetricStatusTile(
              metric: metric,
              requesting: requestingMetrics.contains(metric),
              onRequest: () => onRequestMetric(metric),
            ),
        ],
      );
    }
    if (result.status == HealthAuthorizationResult.statusCompleted) {
      final byMetric = <HealthMetricType, HealthMetricAuthorizationResult>{
        for (final metric in result.metrics) metric.metric: metric,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Request completed. iOS does not expose read permission state to apps, so the app verifies whether data is visible.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          for (final metric in HealthSummaryMetricLabels.defaultMetrics)
            _MetricStatusTile(
              metric: metric,
              result: byMetric[metric],
              requesting: requestingMetrics.contains(metric),
              onRequest: () => onRequestMetric(metric),
            ),
        ],
      );
    }
    return Text(
      'Apple Health is unavailable or the authorization request did not complete.',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
  }
}

class _MetricStatusTile extends StatelessWidget {
  const _MetricStatusTile({
    required this.metric,
    required this.requesting,
    required this.onRequest,
    this.result,
  });

  final HealthMetricType metric;
  final HealthMetricAuthorizationResult? result;
  final bool requesting;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readable =
        result?.status == HealthMetricAuthorizationResult.statusReadable;
    final unavailable = result?.status == HealthSummaryStatus.unavailable;
    final permissionDenied =
        result?.status == HealthSummaryStatus.permissionDenied;
    final color = readable
        ? theme.colorScheme.primary
        : unavailable || permissionDenied
        ? theme.colorScheme.error
        : theme.colorScheme.secondary;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(readable ? Icons.check_circle : Icons.info, color: color),
      title: Text(metric.label),
      subtitle: Text(_statusText()),
      trailing: OutlinedButton(
        key: ValueKey<String>('health_authorize_${metric.wireName}_button'),
        onPressed: requesting ? null : onRequest,
        child: Text(requesting ? 'Checking...' : 'Authorize'),
      ),
    );
  }

  String _statusText() {
    final result = this.result;
    if (result == null) {
      return 'Not checked yet.';
    }
    if (result.status == HealthMetricAuthorizationResult.statusReadable) {
      return 'Readable${_summaryText()}';
    }
    if (result.status == HealthSummaryStatus.unavailable) {
      return 'Unavailable';
    }
    if (result.status == HealthSummaryStatus.permissionDenied) {
      return 'Request failed or was not completed.';
    }
    return 'No visible data. Confirm this Health permission toggle and that Health has data for the period.';
  }

  String _summaryText() {
    final result = this.result;
    final summary = result?.summary;
    if (summary == null) {
      return '';
    }
    final sampleCount = summary['sample_count'];
    final value = summary['value'];
    final average = summary['average'];
    final unit = summary['unit'];
    final amount = value ?? average;
    if (amount == null || unit == null || sampleCount == null) {
      return '';
    }
    return ' - $amount $unit, sample count $sampleCount';
  }
}

abstract final class HealthSummaryStatus {
  static const String unavailable = 'unavailable';
  static const String permissionDenied = 'permission_denied';
}

extension HealthSummaryMetricLabels on HealthMetricType {
  static const List<HealthMetricType> defaultMetrics = <HealthMetricType>[
    HealthMetricType.steps,
    HealthMetricType.sleepSession,
    HealthMetricType.heartRate,
    HealthMetricType.hrv,
    HealthMetricType.activeEnergy,
  ];

  String get label {
    return switch (this) {
      HealthMetricType.steps => 'Steps',
      HealthMetricType.sleepSession => 'Sleep',
      HealthMetricType.heartRate => 'Heart Rate',
      HealthMetricType.hrv => 'HRV',
      HealthMetricType.activeEnergy => 'Active Energy',
    };
  }
}
