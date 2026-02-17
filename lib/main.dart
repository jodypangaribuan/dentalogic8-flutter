
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:persistent_bottom_nav_bar_v2/persistent_bottom_nav_bar_v2.dart';

import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/scan/scan_screen.dart';
import 'features/analysis/analysis_detail_screen.dart';
import 'features/history/history_screen.dart';
import 'data/models/detection.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set preferred orientation
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const DentalCariesApp());
}

class DentalCariesApp extends StatelessWidget {
  const DentalCariesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dentalogic8',
      theme: AppTheme.lightTheme,
      debugShowCheckedModeBanner: false,
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(builder: (_) => const MainTabScaffold());
          case '/scan':
            return MaterialPageRoute(builder: (_) => const ScanScreen());
          case '/analysis-detail':
            final args = settings.arguments as Map<String, dynamic>? ?? {};
            return MaterialPageRoute(
              builder: (_) => AnalysisDetailScreen(
                imageUri: args['imageUri'] as String? ?? '',
                source: args['source'] as String? ?? 'gallery',
                preDetections: args['initialDetections'] as List<DetectionResult>?,
                historyId: args['historyId'] as String?,
                preLabel: args['preLabel'] as String?,
                preConfidence: args['preConfidence'] as double?,
                preInferenceTime: args['preInferenceTime'] as int?,
              ),
            );
          default:
            return MaterialPageRoute(builder: (_) => const MainTabScaffold());
        }
      },
    );
  }
}

class MainTabScaffold extends StatefulWidget {
  const MainTabScaffold({super.key});

  @override
  State<MainTabScaffold> createState() => _MainTabScaffoldState();
}

class _MainTabScaffoldState extends State<MainTabScaffold> {
  late PersistentTabController _controller;
  int _lastSelectedTab = 0;

  @override
  void initState() {
    super.initState();
    _controller = PersistentTabController(initialIndex: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PersistentTabView(
      controller: _controller,
      tabs: [
        PersistentTabConfig(
          screen: const HomeScreen(),
          item: ItemConfig(
            icon: const Icon(Icons.home),
            title: "Home",
            activeForegroundColor: AppColors.primary,
            inactiveForegroundColor: Colors.grey,
          ),
        ),
        PersistentTabConfig(
          screen: const SizedBox(), // Scan is handled by onItemSelected
          item: ItemConfig(
            icon: const Icon(Icons.camera_alt),
            title: "Scan",
            activeForegroundColor: AppColors.primary,
            inactiveForegroundColor: Colors.grey,
          ),
        ),
        PersistentTabConfig(
          screen: const HistoryScreen(),
          item: ItemConfig(
            icon: const Icon(Icons.history),
            title: "Riwayat",
            activeForegroundColor: AppColors.primary,
            inactiveForegroundColor: Colors.grey,
          ),
        ),
      ],
      navBarBuilder: (navBarConfig) => Style1BottomNavBar(
        navBarConfig: navBarConfig,
        navBarDecoration: NavBarDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10.0),
          filter: null, // Optional: backdrop filter
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 10,
              offset: const Offset(0, -2), // Shadow upwards
            ),
          ],
        ),
      ),
      onTabChanged: (index) {
        if (index == 1) {
           // Revert to previous tab so the bottom nav state doesn't change to "Scan"
           _controller.jumpToTab(_lastSelectedTab);
           Navigator.pushNamed(context, '/scan');
        } else {
           _lastSelectedTab = index;
        }
      },
    );
  }
}
