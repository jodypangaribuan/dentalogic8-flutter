
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  int _currentIndex = 0;
  
  // Only Home and History in the stack. Scan is a modal action.
  final List<Widget> _screens = [
    const HomeScreen(),
    const HistoryScreen(), 
  ];

  void _onItemTapped(int index) {
    if (index == 1) {
      // Scan Action
      Navigator.pushNamed(context, '/scan');
    } else {
      // Index 0 (Home) stays 0.
      // Index 2 (History) maps to 1 in _screens? 
      // This mapping is annoying.
      // Let's use indices 0, 1, 2 and a placeholder.
      setState(() {
        _currentIndex = index;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        // Map _currentIndex to stack index.
        // 0 -> 0
        // 1 -> 0 (Stay on Home if somehow 1 is set?) OR just don't show 1.
        // 2 -> 1
        index: _currentIndex == 2 ? 1 : 0, 
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onItemTapped,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
             icon: Icon(Icons.camera_alt_outlined),
             label: 'Scan',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'Riwayat',
          ),
        ],
      ),
    );
  }
}
