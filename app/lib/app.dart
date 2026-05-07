import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'presentation/app_navigation_drawer.dart';
import 'presentation/chat/chat_page.dart';

final GoRouter _router = GoRouter(
  initialLocation: '/chat',
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      redirect: (BuildContext context, GoRouterState state) => '/chat',
    ),
    GoRoute(
      path: '/chat',
      builder: (BuildContext context, GoRouterState state) {
        return const ChatPage();
      },
    ),
    GoRoute(
      path: '/apple-health',
      builder: (BuildContext context, GoRouterState state) {
        return const FeaturePlaceholderPage(
          title: 'Apple Health',
          currentPath: '/apple-health',
        );
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

class GemmaLocalApp extends StatelessWidget {
  const GemmaLocalApp({super.key});

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
