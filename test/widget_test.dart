import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_creator_hub/main.dart';

void main() {
  setUp(() {
    // ThemeProvider and ConversationProvider both read SharedPreferences on
    // startup; mock it so widget tests don't hit a real platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App launches straight into Chat with the trimmed nav bar',
      (tester) async {
    await tester.pumpWidget(const PakAIApp());
    await tester.pumpAndSettle();

    // Step 16: Chat is tab 0 (the app's default/opening screen) and its
    // empty state greets the person immediately — no more Home dashboard.
    expect(find.text('What can I do\nfor you?'), findsOneWidget);

    // Bottom navigation is trimmed to exactly these 4 destinations.
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);

    // The removed dashboard/tool tabs are gone.
    expect(find.text('Home'), findsNothing);
    expect(find.text('Tools'), findsNothing);
  });
}
