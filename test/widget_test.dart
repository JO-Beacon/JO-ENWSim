import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/main.dart';

void main() {
  testWidgets('壳能启动', (WidgetTester tester) async {
    await tester.pumpWidget(const JoEnwsApp());
    expect(find.text('JO-ENWSim'), findsOneWidget);
  });
}
