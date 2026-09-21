import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/lens_lut.dart';
import 'package:iphone_follow_focus/main.dart';

void main() {
  testWidgets('follow app shows controls', (tester) async {
    await tester.pumpWidget(FollowApp(lut: LensLut(const [])));
    expect(find.text('跟焦器'), findsOneWidget);
    expect(find.text('连接电机'), findsOneWidget);
    expect(find.text('记录当前'), findsOneWidget);
  });
}
