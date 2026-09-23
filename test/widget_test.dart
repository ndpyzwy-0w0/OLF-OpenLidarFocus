import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/lens.dart';
import 'package:iphone_follow_focus/main.dart';

void main() {
  testWidgets('app starts on the lens picker', (tester) async {
    await tester.pumpWidget(FollowApp(store: LensStore([])));
    expect(find.text('选择镜头'), findsOneWidget);
    expect(find.text('新建镜头'), findsOneWidget);
  });

  testWidgets('picker shows stored lenses and their calibration state',
      (tester) async {
    await tester.pumpWidget(FollowApp(
      store: LensStore([
        Lens(id: 'a', name: '50mm F1.4', strokeSteps: 6400, strokeMicrosteps: 16),
        Lens(id: 'b', name: '85mm'),
      ]),
    ));
    expect(find.text('50mm F1.4'), findsOneWidget);
    expect(find.text('85mm'), findsOneWidget);
    expect(find.textContaining('未标定行程'), findsOneWidget);
  });

  testWidgets('new lens opens into stroke calibration', (tester) async {
    final lens = Lens(id: 'a', name: '50mm');
    await tester.pumpWidget(MaterialApp(
      home: FollowPage(lens: lens, store: LensStore([lens])),
    ));
    expect(find.text('① 标定行程'), findsWidgets);
    expect(find.text('记录这一端 A'), findsOneWidget);
  });

  testWidgets('calibrated lens opens straight into single-side alignment',
      (tester) async {
    Lens make() =>
        Lens(id: 'a', name: '50mm', strokeSteps: 6400, strokeMicrosteps: 16);
    await tester.pumpWidget(MaterialApp(
      home: FollowPage(lens: make(), store: LensStore([make()])),
    ));
    expect(find.text('② 单侧对齐'), findsWidgets);
    expect(find.text('确认为焦距最近点'), findsOneWidget);
    // 还没对齐，跟焦面板不该出现。
    expect(find.text('记录当前'), findsNothing);
  });
}
