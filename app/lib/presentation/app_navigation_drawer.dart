import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({required this.currentPath, super.key});

  final String currentPath;

  static const List<_NavigationItem> _items = <_NavigationItem>[
    _NavigationItem(label: 'Chat', path: '/chat', icon: Icons.chat_bubble),
    _NavigationItem(label: 'Diet', path: '/diet', icon: Icons.restaurant),
    _NavigationItem(label: 'Sleep', path: '/sleep', icon: Icons.bedtime),
    _NavigationItem(
      label: 'Chronic Care',
      path: '/chronic',
      icon: Icons.monitor_heart,
    ),
    _NavigationItem(
      label: 'Reminders',
      path: '/reminders',
      icon: Icons.notifications,
    ),
    _NavigationItem(label: 'Reports', path: '/reports', icon: Icons.article),
    _NavigationItem(label: 'Settings', path: '/settings', icon: Icons.settings),
  ];

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Text(
                'Gemma Health Coach',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final item in _items)
              ListTile(
                leading: Icon(item.icon),
                title: Text(item.label),
                selected: currentPath == item.path,
                onTap: () {
                  Navigator.of(context).pop();
                  if (currentPath != item.path) {
                    context.go(item.path);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class FeaturePlaceholderPage extends StatelessWidget {
  const FeaturePlaceholderPage({
    required this.title,
    required this.currentPath,
    super.key,
  });

  final String title;
  final String currentPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      drawer: AppNavigationDrawer(currentPath: currentPath),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.construction,
                size: 40,
                color: theme.colorScheme.secondary,
              ),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Planned local-first feature. Not connected yet.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationItem {
  const _NavigationItem({
    required this.label,
    required this.path,
    required this.icon,
  });

  final String label;
  final String path;
  final IconData icon;
}
