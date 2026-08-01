import 'package:flutter/material.dart';

import '../screens/home_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/tools_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/settings_screen.dart';

/// Root shell of the app: hosts the bottom [NavigationBar] (Material 3)
/// and switches between the 5 primary tabs using an [IndexedStack]
/// so each tab keeps its own state when you switch away and back.
class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _tabs = const [
    HomeScreen(),
    ChatScreen(),
    ToolsScreen(),
    ProfileScreen(),
    SettingsScreen(),
  ];

  // Step 12.1: each tab now carries its own accent color, applied to its
  // icon and selection indicator only when active — everything else
  // (order, screens, navigation logic) is unchanged.
  final List<({IconData icon, IconData selectedIcon, String label, Color accent})>
      _destinations = const [
    (
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      label: 'Home',
      accent: Color(0xFF6C5CE7), // matches the app's default violet
    ),
    (
      icon: Icons.chat_bubble_outline_rounded,
      selectedIcon: Icons.chat_bubble_rounded,
      label: 'Chat',
      accent: Color(0xFF10B981), // emerald
    ),
    (
      icon: Icons.auto_awesome_outlined,
      selectedIcon: Icons.auto_awesome_rounded,
      label: 'Tools',
      accent: Color(0xFFFB923C), // orange
    ),
    (
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: 'Profile',
      accent: Color(0xFF3B82F6), // blue
    ),
    (
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
      accent: Color(0xFF9CA3AF), // gray
    ),
  ];

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
        // Overridden per selection so the pill indicator matches the
        // active tab's own accent instead of one fixed app-wide color.
        indicatorColor: selectedAccent.withOpacity(0.16),
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: [
          for (int i = 0; i < _destinations.length; i++)
            NavigationDestination(
              icon: Icon(
                _destinations[i].icon,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              selectedIcon: Icon(
                _destinations[i].selectedIcon,
                color: _destinations[i].accent,
              ),
              label: _destinations[i].label,
            ),
        ],
      ),
    );
  }
}
