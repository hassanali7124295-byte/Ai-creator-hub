import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'core/providers/theme_provider.dart';
import 'core/providers/conversation_provider.dart';
import 'screens/chat_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // NOTE: Gemini API client setup (Phase 2) and AdMob initialization
  // (Phase 4, once google_mobile_ads is added back to pubspec.yaml) will
  // be wired in here.

  runApp(const PakAIApp());
}

/// Step 16 renamed this from `AiCreatorHubApp`; Step 17 removed the bottom
/// tab bar entirely — [ChatScreen] is now the app's single root screen,
/// and its drawer (see `ConversationDrawer`) is the only navigation
/// surface, linking out to History, Settings, Profile, Rate App, Privacy
/// Policy, and About. Nothing about the app's bootstrap (providers,
/// theming) changed shape.
class PakAIApp extends StatelessWidget {
  const PakAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        // Owns the multi-conversation chat list (Step 12) — created once
        // here, not inside ChatScreen, so it (and the "last opened chat"
        // it remembers) survives pushes to History/Settings/Profile and
        // back for the whole lifetime of the app.
        ChangeNotifierProvider(create: (_) => ConversationProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            title: 'Pak AI',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeProvider.themeMode,
            home: const ChatScreen(),
          );
        },
      ),
    );
  }
}
