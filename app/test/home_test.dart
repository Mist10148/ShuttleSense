import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/home/home_screen.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

void main() {
  testWidgets('first run offers the first upload', (tester) async {
    await pumpScreen(tester, const HomeScreen(), api: FakeApiClient(jobs: []));
    expect(find.text('Upload your first rally'), findsOneWidget);
    expect(find.text('Recent analyses'), findsNothing);
  });

  testWidgets('with analyses it lists the recent ones', (tester) async {
    await pumpScreen(tester, const HomeScreen());
    expect(find.text('Recent analyses'), findsOneWidget);
    expect(find.text('rally01.mp4'), findsWidgets);
    expect(find.text('Upload your first rally'), findsNothing);
  });
}
