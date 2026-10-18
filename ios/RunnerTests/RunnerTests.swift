import Flutter
import ImageIO
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  func testLidarUIEventsAreBoundedWhileTheMainThreadIsBusy() {
    let engine = LidarEngine()
    var deliveries = 0
    engine.setEventSink { _ in deliveries += 1 }
    for _ in 0..<8 {
      engine.emit(distance: 1)
      Thread.sleep(forTimeInterval: 0.04)
    }
    let delivered = expectation(description: "queued event delivered")
    DispatchQueue.main.async { delivered.fulfill() }
    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(deliveries, 1)
    engine.setEventSink(nil)
  }

  func testCancellingLidarEventsDropsQueuedSamples() {
    let engine = LidarEngine()
    var deliveries = 0
    engine.setEventSink { _ in deliveries += 1 }
    engine.emit(distance: 1)
    engine.setEventSink(nil)
    engine.setEventSink { _ in deliveries += 1 }
    let drained = expectation(description: "old subscription drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
    XCTAssertEqual(deliveries, 0)
    engine.setEventSink(nil)
  }

  func testVisionOrientationMatchesPreviewRotationWithoutRotatingPortraitAgain() {
    XCTAssertEqual(LidarEngine.visionOrientation(for: 0), .up)
    XCTAssertEqual(LidarEngine.visionOrientation(for: -1), .left)
    XCTAssertEqual(LidarEngine.visionOrientation(for: 1), .right)
    XCTAssertEqual(LidarEngine.visionOrientation(for: 2), .down)
  }

  func testFaceBoxAndMovementStayInPortraitDepthCoordinatesForEveryOrientation() {
    // The same off-center, non-square face in Vision's four oriented images.
    // The second box represents the face moving right and down in the buffer.
    let cases: [(CGImagePropertyOrientation, CGRect, CGRect)] = [
      (.up, CGRect(x: 0.2, y: 0.45, width: 0.15, height: 0.25),
            CGRect(x: 0.3, y: 0.35, width: 0.15, height: 0.25)),
      (.left, CGRect(x: 0.3, y: 0.2, width: 0.25, height: 0.15),
              CGRect(x: 0.4, y: 0.3, width: 0.25, height: 0.15)),
      (.right, CGRect(x: 0.45, y: 0.65, width: 0.25, height: 0.15),
               CGRect(x: 0.35, y: 0.55, width: 0.25, height: 0.15)),
      (.down, CGRect(x: 0.65, y: 0.3, width: 0.15, height: 0.25),
              CGRect(x: 0.55, y: 0.4, width: 0.15, height: 0.25)),
    ]
    for (orientation, box, movedBox) in cases {
      let rect = LidarEngine.portraitFaceRect(box, orientation: orientation)
      let moved = LidarEngine.portraitFaceRect(movedBox, orientation: orientation)
      XCTAssertEqual(rect.minX, 0.2, accuracy: 1e-9, "\(orientation)")
      XCTAssertEqual(rect.minY, 0.3, accuracy: 1e-9, "\(orientation)")
      XCTAssertEqual(rect.width, 0.15, accuracy: 1e-9, "\(orientation)")
      XCTAssertEqual(rect.height, 0.25, accuracy: 1e-9, "\(orientation)")
      XCTAssertEqual(moved.midX - rect.midX, 0.1, accuracy: 1e-9, "\(orientation)")
      XCTAssertEqual(moved.midY - rect.midY, 0.1, accuracy: 1e-9, "\(orientation)")
    }
  }

  func testPortraitPreviewStaysUprightInBothLandscapeDirections() {
    // A portrait camera sees world-up on the right when Home is on the right.
    // Rotate that image counterclockwise to bring world-up to the screen top.
    XCTAssertEqual(LidarPreviewView.quarterTurns(for: .landscapeRight), -1)
    XCTAssertEqual(LidarPreviewView.quarterTurns(for: .landscapeLeft), 1)
    XCTAssertEqual(LidarPreviewView.quarterTurns(for: .portrait), 0)
    XCTAssertEqual(LidarPreviewView.quarterTurns(for: .portraitUpsideDown), 2)
    XCTAssertEqual(LidarPreviewView.quarterTurns(for: .unknown), 0)
  }

}
