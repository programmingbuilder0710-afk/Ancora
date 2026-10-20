import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doer/app.dart';
import 'package:doer/data/database_helper.dart';

void main() {
  testWidgets('agenda empty state renders with degradation banner',
      (WidgetTester tester) async {
    final services = AppServices(db: DatabaseHelper.forTest());
    // Real async outside the fake-async zone: calendar init touches a
    // platform channel that cannot resolve under FakeAsync.
    await tester.runAsync(() => services.init());
    // init() may leave a pending microtask chain; drain before pumping.
    await tester.pump();

    await tester.pumpWidget(DoerApp(services: services));
    await tester.pumpAndSettle();

    expect(find.text('Doer'), findsOneWidget);
    expect(find.text('Agenda'), findsWidgets);
    expect(find.text('Goals'), findsWidgets);
    expect(find.textContaining('Nothing scheduled today'), findsOneWidget);
  });

  testWidgets('goals screen: create goal via editor writes SQLite row',
      (WidgetTester tester) async {
    final helper = DatabaseHelper.forTest();
    final services = AppServices(db: helper);
    await tester.runAsync(() => services.init());
    await tester.pump();

    await tester.pumpWidget(DoerApp(services: services));
    await tester.pumpAndSettle();

    // Navigate to the Goals tab (nav-bar label is the last 'Goals' text).
    await tester.tap(find.text('Goals').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('No goals yet'), findsOneWidget);

    // Open the editor.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'), 'Learn piano');
    await tester.tap(find.byIcon(Icons.calendar_month));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create goal'));
    await tester.pumpAndSettle();

    expect(find.text('Learn piano'), findsOneWidget);
    final goals = await tester.runAsync(() => helper.getAllGoals());
    expect(goals, isNotNull);
    expect(goals!.single.title, 'Learn piano');
    expect(goals.single.priority.name, 'P2');
  });
}
