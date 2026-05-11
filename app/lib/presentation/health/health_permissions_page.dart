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

  Future<void> _openSettings() async {
    await ref.read(healthAuthorizationServiceProvider).openAppSettings();
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
            'Authorize Apple Health once so the local assistant can read the health data it needs on demand.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Data stays on this device. The app requests all supported Health data types in one Apple Health permission request.',
            style: theme.textTheme.bodySmall,
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
              label: Text(
                _requesting ? 'Requesting...' : 'Authorize Apple Health Once',
              ),
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
          _PermissionStatus(result: _result, error: _error),
        ],
      ),
    );
  }
}

class _PermissionStatus extends StatelessWidget {
  const _PermissionStatus({required this.result, required this.error});

  final HealthAuthorizationResult? result;
  final Object? error;

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
      return Text(
        'Tap authorize once. If iOS does not show the permission sheet, open Settings or Health and enable Gemma Local health access.',
        style: theme.textTheme.bodyMedium,
      );
    }
    if (result.metrics.isNotEmpty) {
      final readableCount = result.metrics
          .where(
            (metric) =>
                metric.status == HealthAuthorizationService.statusReadable,
          )
          .length;
      final missing = result.metrics
          .where(
            (metric) =>
                metric.status == HealthAuthorizationService.statusNoVisibleData,
          )
          .toList(growable: false);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            result.status == HealthAuthorizationService.statusCompleted
                ? 'Apple Health request completed once. Visible health categories: $readableCount/${result.metrics.length}.'
                : 'Apple Health request failed or did not complete. Retry once, or check iOS Health permissions for Gemma Local.',
            style: theme.textTheme.bodyMedium,
          ),
          if (missing.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text('Needs attention', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              missing.map((metric) => metric.metric.displayName).join(', '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'iOS returned no visible data. Check Health > Sharing > Apps > Gemma Local and make sure these data types are enabled, and confirm Health contains data.',
              style: theme.textTheme.bodySmall,
            ),
          ],
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
