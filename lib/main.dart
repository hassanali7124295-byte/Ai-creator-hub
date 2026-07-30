import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'core/providers/theme_provider.dart';
import 'widgets/main_navigation.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // NOTE: Gemini API client setup (Phase 2) and AdMob initialization
  // (Phase 4, once google_mobile_ads is added back to pubspec.yaml) will
  // be wired in here.

  runApp(const AiCreatorHubApp());
}

class AiCreatorHubApp extends StatelessWidget {
  const AiCreatorHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            title: 'AI Creator Hub',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeProvider.themeMode,
            home: const MainNavigation(),
          );
        },
      ),
    );
  }
}
