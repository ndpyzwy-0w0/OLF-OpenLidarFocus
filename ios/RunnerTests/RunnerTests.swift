import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

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
