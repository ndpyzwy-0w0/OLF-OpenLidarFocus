import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit
import Vision

final class LidarEngine: NSObject, AVCaptureDataOutputSynchronizerDelegate {
  static let shared = LidarEngine()

  let session = AVCaptureSession()
  private let videoOut = AVCaptureVideoDataOutput()
  private let depthOut = AVCaptureDepthDataOutput()
  private var sync: AVCaptureDataOutputSynchronizer?
  private let camQueue = DispatchQueue(label: "ff.lidar.cam")
  private var configured = false
  private var frameIndex = 0
  private var lastDistance: Double?
  private var lastEmit = Date.distantPast

  // These values are owned by camQueue. Flutter callbacks are owned by main.
  private let sinkLock = NSLock()
  private var eventSink: FlutterEventSink?
  private var target = CGPoint(x: 0.5, y: 0.5)
  private var trackFaces = false
  private var face: CGRect?

  func available() -> Bool {
    AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
  }

  func setEventSink(_ sink: FlutterEventSink?) {
    sinkLock.lock()
    eventSink = sink
    sinkLock.unlock()
  }

  func start() {
    AVCaptureDevice.requestAccess(for: .video) { ok in
      guard ok else { return }
      self.camQueue.async { self.startOnCamQueue() }
    }
  }

  func stop() {
    camQueue.async {
      if self.session.isRunning { self.session.stopRunning() }
    }
  }

  func setTarget(u: Double, v: Double) {
    camQueue.async {
      self.target = CGPoint(x: min(max(u, 0), 1), y: min(max(v, 0), 1))
      self.lastEmit = .distantPast
      self.emit(distance: self.lastDistance)
    }
  }

  func setTrackFaces(_ on: Bool) {
    camQueue.async {
      self.trackFaces = on
      if !on { self.face = nil }
    }
  }

  private func startOnCamQueue() {
    if !configured {
      do { try configure() } catch { return }
    }
    if !session.isRunning { session.startRunning() }
  }

  private func configure() throws {
    guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
      throw NSError(domain: "ff.lidar", code: 1)
    }
    session.beginConfiguration()
    session.sessionPreset = .vga640x480
    let input = try AVCaptureDeviceInput(device: device)
    if session.canAddInput(input) { session.addInput(input) }
    videoOut.alwaysDiscardsLateVideoFrames = true
    videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
    depthOut.isFilteringEnabled = true
    if session.canAddOutput(depthOut) { session.addOutput(depthOut) }
    if let c = videoOut.connection(with: .video), c.isVideoOrientationSupported {
      c.videoOrientation = .portrait
    }
    if let c = depthOut.connection(with: .depthData), c.isVideoOrientationSupported {
      c.videoOrientation = .portrait
    }
    let s = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOut, depthOut])
    s.setDelegate(self, queue: camQueue)
    sync = s
    session.commitConfiguration()
    configured = true
  }

  func dataOutputSynchronizer(
    _ synchronizer: AVCaptureDataOutputSynchronizer,
    didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
  ) {
    guard
      let vData = synchronizedDataCollection.synchronizedData(for: videoOut) as? AVCaptureSynchronizedSampleBufferData,
      !vData.sampleBufferWasDropped,
      let dData = synchronizedDataCollection.synchronizedData(for: depthOut) as? AVCaptureSynchronizedDepthData,
      !dData.depthDataWasDropped
    else { return }

    frameIndex += 1
    if trackFaces, frameIndex % 3 == 0, let pb = CMSampleBufferGetImageBuffer(vData.sampleBuffer) {
      updateFace(pb)
    } else if !trackFaces {
      face = nil
    }

    let depth = dData.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    let meters = medianMeters(depth.depthDataMap, u: target.x, v: target.y)
    if let meters {
      lastDistance = meters
    }
    emit(distance: lastDistance)
  }

  private func updateFace(_ pb: CVPixelBuffer) {
    let req = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
    try? handler.perform([req])
    let obs = (req.results as? [VNFaceObservation]) ?? []
    guard !obs.isEmpty else {
      face = nil
      return
    }
    let chosen = obs.min(by: { a, b in
      dist(a) < dist(b)
    })!
    let box = chosen.boundingBox
    let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    face = rect
    target = CGPoint(x: rect.midX, y: min(rect.midY + rect.height * 0.35, 0.98))
  }

  private func dist(_ o: VNFaceObservation) -> CGFloat {
    let u = o.boundingBox.midX
    let v = 1 - o.boundingBox.midY
    let du = u - target.x
    let dv = v - target.y
    return du * du + dv * dv
  }

  private func medianMeters(_ pb: CVPixelBuffer, u: CGFloat, v: CGFloat) -> Double? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let cx = min(max(Int(u * CGFloat(w)), 0), w - 1)
    let cy = min(max(Int(v * CGFloat(h)), 0), h - 1)
    let r = 4
    var vals: [Float] = []
    vals.reserveCapacity(81)
    for y in max(0, cy - r)...min(h - 1, cy + r) {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
      for x in max(0, cx - r)...min(w - 1, cx + r) {
        let z = row[x]
        if z.isFinite, z >= 0.15, z <= 5.5 { vals.append(z) }
      }
    }
    guard !vals.isEmpty else { return nil }
    vals.sort()
    return Double(vals[vals.count / 2])
  }

  func emit(distance: Double?) {
    let now = Date()
    if now.timeIntervalSince(lastEmit) < 0.03 { return }
    lastEmit = now
    var map: [String: Any] = [
      "u": target.x,
      "v": target.y,
    ]
    if let distance { map["distance_m"] = distance }
    map["schema_version"] = 1
    map["timestamp_ms"] = Int64(now.timeIntervalSince1970 * 1000)
    map["valid"] = distance != nil
    map["target_u"] = target.x
    map["target_v"] = target.y
    // Keep u/v and face_* for existing UI callers while the versioned fields
    // give new Flutter code an explicit, stable contract.
    map["u"] = target.x
    map["v"] = target.y
    map["distance_m"] = distance ?? NSNull()
    if let face {
      map["face_u"] = face.origin.x
      map["face_v"] = face.origin.y
      map["face_w"] = face.size.width
      map["face_h"] = face.size.height
    }
    sinkLock.lock()
    let sink = eventSink
    sinkLock.unlock()
    DispatchQueue.main.async { sink?(map) }
  }
}

final class LidarPreviewView: UIView {
  let preview = AVCaptureVideoPreviewLayer(session: LidarEngine.shared.session)

  override init(frame: CGRect) {
    super.init(frame: frame)
    preview.videoGravity = .resizeAspectFill
    layer.addSublayer(preview)
    let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
    addGestureRecognizer(tap)
    backgroundColor = .black
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    preview.frame = bounds
  }

  @objc private func onTap(_ g: UITapGestureRecognizer) {
    let p = g.location(in: self)
    guard bounds.width > 0, bounds.height > 0 else { return }
    LidarEngine.shared.setTarget(u: p.x / bounds.width, v: p.y / bounds.height)
  }
}

final class LidarPreview: NSObject, FlutterPlatformView {
  private let view_: LidarPreviewView
  init(frame: CGRect) {
    view_ = LidarPreviewView(frame: frame)
    super.init()
  }
  func view() -> UIView { view_ }
}

final class LidarPreviewFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    LidarPreview(frame: frame)
  }
}

final class LidarPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LidarPlugin()
    let methods = FlutterMethodChannel(name: "ff.lidar", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "ff.lidar/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    registrar.register(LidarPreviewFactory(), withId: "ff.lidar/preview")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(LidarEngine.shared.available())
    case "start":
      let args = call.arguments as? [String: Any]
      if let on = args?["trackFaces"] as? Bool {
        LidarEngine.shared.setTrackFaces(on)
      }
      LidarEngine.shared.start()
      result(nil)
    case "stop":
      LidarEngine.shared.stop()
      result(nil)
    case "setTarget":
      let args = call.arguments as? [String: Any]
      let u = (args?["u"] as? NSNumber)?.doubleValue ?? 0.5
      let v = (args?["v"] as? NSNumber)?.doubleValue ?? 0.5
      LidarEngine.shared.setTarget(u: u, v: v)
      result(nil)
    case "setTrackFaces":
      let args = call.arguments as? [String: Any]
      LidarEngine.shared.setTrackFaces((args?["on"] as? Bool) ?? false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    DispatchQueue.main.async { LidarEngine.shared.setEventSink(events) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    DispatchQueue.main.async { LidarEngine.shared.setEventSink(nil) }
    return nil
  }
}
