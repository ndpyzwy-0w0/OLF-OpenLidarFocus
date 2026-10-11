import XCTest
@testable import FollowFocusCore
final class MotorCalTests: XCTestCase {
  func testFm03NormalizedTravelDoesNotDependOnLegacyMicrosteps() {
    let c=MotorCal()
    XCTAssertEqual(c.stepsPerRev(1),4096); XCTAssertEqual(c.stepsPerRev(256),4096)
    XCTAssertEqual(c.revsToSteps(0.5,1),2048); XCTAssertEqual(c.stepsToRevs(1024,1),0.25)
    XCTAssertEqual(c.revsToSteps(.nan,1),0)
    XCTAssertEqual(c.revsToSteps(20,1),4096)
    XCTAssertEqual(c.defaultLimitSpan(1),4096)
  }
}
