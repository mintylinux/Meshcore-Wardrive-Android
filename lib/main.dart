import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static _MyAppState? of(BuildContext context) {
    return context.findAncestorStateOfType<_MyAppState>();
  }
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;
  
  ThemeMode get themeMode => _themeMode;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeString = prefs.getString('theme_mode') ?? 'system';
    setState(() {
      _themeMode = ThemeMode.values.firstWhere(
        (e) => e.name == themeModeString,
        orElse: () => ThemeMode.system,
      );
    });
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    setState(() {
      _themeMode = mode;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshCore Wardrive',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
      ),
      home: const MapScreen(),
    );
  }
}
