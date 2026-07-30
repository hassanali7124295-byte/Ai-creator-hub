import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_creator_hub/main.dart';

void main() {
  setUp(() {
    // ThemeProvider reads SharedPreferences on startup; mock it so widget
    // tests don't hit a real platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App launches and shows the home dashboard', (tester) async {
    await tester.pumpWidget(const AiCreatorHubApp());
    await tester.pumpAndSettle();

    expect(find.text('AI Creator Hub'), findsOneWidget);
    expect(find.text('Create something amazing'), findsOneWidget);

    // Bottom navigation destinations are all present.
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
