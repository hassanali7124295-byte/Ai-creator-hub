import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/chat_screen.dart';
import '../screens/history_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/settings_screen.dart';

/// Root shell of Pak AI (Step 16): hosts the bottom [NavigationBar]
/// (Material 3) and switches between the 4 primary tabs — Chat, History,
/// Settings, Profile — using an [IndexedStack] so each tab keeps its own
/// state when you switch away and back.
///
/// Chat is the app's main feature now, so it's tab 0 (previously Home was
/// tab 0 and Chat was tab 1) — the app opens straight into the chat.
class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  /// Switches to the Chat tab from anywhere below this widget in the tree
  /// — used by [HistoryScreen] after picking a conversation, so tapping a
  /// history item both loads that conversation and brings Chat on screen.
  static void jumpToChat(BuildContext context) {
    context.findAncestorStateOfType<_MainNavigationState>()?._jumpToChat();
  }

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _tabs = const [
    ChatScreen(),
    HistoryScreen(),
    SettingsScreen(),
    ProfileScreen(),
  ];

  // Step 12.1 (carried into Step 16): each tab carries its own accent
  // color, applied to its icon and selection indicator only when active.
  final List<({IconData icon, IconData selectedIcon, String label, Color accent})>
      _destinations = const [
    (
      icon: Icons.chat_bubble_outline_rounded,
      selectedIcon: Icons.chat_bubble_rounded,
      label: 'Chat',
      accent: Color(0xFF10B981), // emerald — matches ChatPalette
    ),
    (
      icon: Icons.history_rounded,
      selectedIcon: Icons.history_toggle_off_rounded,
      label: 'History',
      accent: Color(0xFF3B82F6), // blue
    ),
    (
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
      accent: Color(0xFF9CA3AF), // gray
    ),
    (
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: 'Profile',
      accent: Color(0xFF6C5CE7), // violet
    ),
  ];

  void _jumpToChat() {
    if (_currentIndex != 0 && mounted) setState(() => _currentIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedAccent = _destinations[_currentIndex].accent;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        // Step 12.2: a longer, easing indicator animation reads as far
        // more premium than the terse Material default.
        animationDuration: const Duration(milliseconds: 420),
        // Overridden per selection so the pill indicator matches the
        // active tab's own accent instead of one fixed app-wide color.
        indicatorColor: selectedAccent.withOpacity(0.16),
        onDestinationSelected: (index) {
          if (index != _currentIndex) HapticFeedback.selectionClick();
          setState(() => _currentIndex = index);
        },
        destinations: [
          for (int i = 0; i < _destinations.length; i++)
            NavigationDestination(
              icon: Icon(
                _destinations[i].icon,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              selectedIcon: TweenAnimationBuilder<double>(
                key: ValueKey('nav-selected-$i-$_currentIndex'),
                tween: Tween(begin: 0.7, end: 1.0),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Icon(
                  _destinations[i].selectedIcon,
                  color: _destinations[i].accent,
                ),
              ),
              label: _destinations[i].label,
            ),
        ],
      ),
    );
  }
}
