import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers/model_management_providers.dart';
import 'presentation/app_navigation_drawer.dart';
import 'presentation/chat/chat_page.dart';
import 'presentation/health/health_permissions_page.dart';
import 'presentation/model/model_setup_page.dart';

class GemmaLocalApp extends ConsumerStatefulWidget {
  const GemmaLocalApp({super.key});

  @override
  ConsumerState<GemmaLocalApp> createState() => _GemmaLocalAppState();
}

class _GemmaLocalAppState extends ConsumerState<GemmaLocalApp>
    with WidgetsBindingObserver {
  late final GoRouter _router = _createRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(
      ref.read(modelConnectionControllerProvider).handleLifecycleState(state),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Gemma Health Coach',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}

GoRouter _createRouter() {
  return GoRouter(
    initialLocation: ModelSetupPage.path,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        redirect: (BuildContext context, GoRouterState state) =>
            ModelSetupPage.path,
      ),
      GoRoute(
        path: ModelSetupPage.path,
        builder: (BuildContext context, GoRouterState state) {
          return const ModelSetupPage();
        },
      ),
      GoRoute(
        path: '/chat',
        builder: (BuildContext context, GoRouterState state) {
          return const ChatPage();
        },
      ),
      GoRoute(
        path: HealthPermissionsPage.path,
        builder: (BuildContext context, GoRouterState state) {
          return const HealthPermissionsPage();
        },
      ),
      GoRoute(
        path: '/diet',
        builder: (BuildContext context, GoRouterState state) {
          return const FeaturePlaceholderPage(
            title: 'Diet',
            currentPath: '/diet',
          );
        },
      ),
      GoRoute(
        path: '/sleep',
        builder: (BuildContext context, GoRouterState state) {
          return const FeaturePlaceholderPage(
            title: 'Sleep',
            currentPath: '/sleep',
          );
        },
      ),
      GoRoute(
        path: '/chronic',
        builder: (BuildContext context, GoRouterState state) {
          return const FeaturePlaceholderPage(
            title: 'Chronic Care',
            currentPath: '/chronic',
          );
        },
      ),
      GoRoute(
        path: '/reminders',
        builder: (BuildContext context, GoRouterState state) {
          return const FeaturePlaceholderPage(
            title: 'Reminders',
            currentPath: '/reminders',
          );
        },
      ),
      GoRoute(
        path: '/reports',
        builder: (BuildContext context, GoRouterState state) {
          return const FeaturePlaceholderPage(
            title: 'Reports',
            currentPath: '/reports',
          );
        },
      ),
      GoRoute(
        path: '/settings',
        builder: (BuildContext context, GoRouterState state) {
          return const FeaturePlaceholderPage(
            title: 'Settings',
            currentPath: '/settings',
          );
        },
      ),
    ],
  );
}
