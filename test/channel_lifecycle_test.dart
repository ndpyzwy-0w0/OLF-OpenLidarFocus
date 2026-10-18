import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/ff_core.dart';
import 'package:iphone_follow_focus/lidar.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in ['ff.core/events', 'ff.lidar/events']) {
    test('$name shares a native subscription across pages', () async {
      var listens = 0;
      var cancels = 0;
      late MockStreamHandlerEventSink events;
      binding.defaultBinaryMessenger.setMockStreamHandler(
        EventChannel(name),
        MockStreamHandler.inline(
          onListen: (_, sink) {
            listens++;
            events = sink;
          },
          onCancel: (_) => cancels++,
        ),
      );
      Stream<Object?> stream() => name == 'ff.core/events'
          ? FfCore().states()
          : LidarChannel().samples();
      final firstEvents = <Object?>[];
      final secondEvents = <Object?>[];
      final first = stream().listen(firstEvents.add);
      final second = stream().listen(secondEvents.add);
      await Future<void>.delayed(Duration.zero);
      expect(listens, 1);
      events.success(<String, Object?>{});
      await Future<void>.delayed(Duration.zero);
      expect(firstEvents, hasLength(1));
      expect(secondEvents, hasLength(1));
      await second.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(cancels, 0);
      events.success(<String, Object?>{});
      await Future<void>.delayed(Duration.zero);
      expect(firstEvents, hasLength(2));
      final cancelled = first.cancel();
      await Future<void>.delayed(Duration.zero);
      await cancelled;
      expect(cancels, 1);
    });
  }
}
