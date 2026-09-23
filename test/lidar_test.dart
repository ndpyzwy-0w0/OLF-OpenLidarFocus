import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/lidar.dart';

void main() {
  test('parses versioned sample and optional face', () {
    final sample = LidarSample.fromMap({
      'schema_version': 1,
      'timestamp_ms': 1234,
      'valid': true,
      'distance_m': 1.25,
      'target_u': .4,
      'target_v': .6,
      'face_u': .1,
      'face_v': .2,
      'face_w': .3,
      'face_h': .4,
    });
    expect(sample.schemaVersion, 1);
    expect(sample.timestampMs, 1234);
    expect(sample.valid, isTrue);
    expect(sample.distanceM, 1.25);
    expect(sample.u, .4);
  });

  test('parses legacy and missing fields safely', () {
    final sample = LidarSample.fromMap({'u': .2, 'v': .8});
    expect(sample.schemaVersion, 0);
    expect(sample.valid, isFalse);
    expect(sample.distanceM, isNull);
    expect(sample.u, .2);
    expect(sample.v, .8);
  });
}
