import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_creator_hub/main.dart';

void main() {
  setUp(() {
    // ThemeProvider and ConversationProvider both read SharedPreferences on
    // startup; mock it so widget tests don't hit a real platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'App launches straight into Chat with no bottom nav (Step 17)',
      (tester) async {
    await tester.pumpWidget(const PakAIApp());
    await tester.pumpAndSettle();

    // Chat is the app's single root screen -- its empty state greets the
    // person immediately, no dashboard/tab bar in between.
    expect(find.text('What can I do\nfor you?'), findsOneWidget);

    // Step 17: the bottom NavigationBar is gone entirely.
    expect(find.byType(NavigationBar), findsNothing);

    // The drawer (hamburger menu) is now the only navigation surface.
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
  });
}
