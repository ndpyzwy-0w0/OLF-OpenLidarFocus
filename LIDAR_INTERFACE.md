# LiDAR interface

Swift owns the rear camera/LiDAR capture session, depth sampling, optional Vision face detection, and the native preview (`ff.lidar/preview`). Flutter owns filtering, lens mapping, and motor policy. No native capture details should be required by Flutter UI code.

## Dart API

Use `LidarChannel` from `lib/lidar.dart`: `available()`, `listen(callback)`, `start(trackFaces: ...)`, `setTrackFaces(bool)`, `setTarget(u, v)`, and `dispose()`. The existing channels remain `ff.lidar` and `ff.lidar/events`.

## Event contract (schema version 1)

Each event is a map containing `schema_version`, `timestamp_ms`, `valid`, `distance_m`, `target_u`, and `target_v`. Coordinates are normalized to 0..1, origin at the top-left. `distance_m` is null and `valid` is false when no usable depth sample exists. When face tracking is enabled, optional `face_u`, `face_v`, `face_w`, and `face_h` describe a normalized face rectangle.

For compatibility, native events also include the legacy `u`/`v` and `face_*` fields. `LidarSample.fromMap` accepts either the versioned fields or the legacy/missing-field form. Unknown future fields must be ignored.

## Lifecycle and limits

Call `available`, then `listen`, then `start`; call `dispose` when the owning Flutter state is destroyed. `stop` stops capture but does not remove the preview view. LiDAR requires a rear LiDAR-equipped iPhone (typically Pro models); the simulator and non-iOS platforms report unsupported. Camera permission is required.
