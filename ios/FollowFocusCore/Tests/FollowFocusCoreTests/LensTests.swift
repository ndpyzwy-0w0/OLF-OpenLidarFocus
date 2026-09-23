import XCTest

@testable import FollowFocusCore

/// 从 Dart 的 `test/lens_test.dart` 逐条搬过来，外加存储的落盘/迁移。
final class LensTests: XCTestCase {
  func testStrokeIsLengthOnlyAndRescalesWithMicrosteps() {
    let l = Lens(id: "1", name: "x", strokeSteps: 6400, strokeMicrosteps: 16)
    XCTAssertTrue(l.calibrated)
    XCTAssertEqual(l.strokeAt(16), 6400)
    // 1/256 is 16x finer, so the same physical travel needs 16x the pulses.
    XCTAssertEqual(l.strokeAt(256), 102400)
    XCTAssertFalse(Lens(id: "2", name: "y").calibrated)
    // 减号只是方向，行程长度取绝对值。
    XCTAssertEqual(
      Lens(id: "3", name: "z", strokeSteps: -6400, strokeMicrosteps: 16).strokeAt(16),
      6400
    )
  }

  func testAlignedRangeOnlyCoversTheFarSideOfTheNearestPoint() {
    XCTAssertEqual(alignedRange(1000, 1, 500).lo, 1000)
    XCTAssertEqual(alignedRange(1000, 1, 500).hi, 1500)
    XCTAssertEqual(alignedRange(1000, -1, 500).lo, 500)
    XCTAssertEqual(alignedRange(1000, -1, 500).hi, 1000)
    // 行程为 0 时退化成一个点，而不是一个反向区间。
    XCTAssertEqual(alignedRange(-3, 1, 0).lo, -3)
    XCTAssertEqual(alignedRange(-3, 1, 0).hi, -3)
  }

  func testInferDirReadsTheDistanceTableDirection() {
    let rising = LensLut([
      LutPoint(meters: 1, steps: 0),
      LutPoint(meters: 3, steps: 900),
    ], microsteps: 16)
    XCTAssertEqual(inferDir(rising), 1)
    let falling = LensLut([
      LutPoint(meters: 1, steps: 900),
      LutPoint(meters: 3, steps: 0),
    ], microsteps: 16)
    XCTAssertEqual(inferDir(falling), -1)
    XCTAssertNil(inferDir(LensLut([])))
  }

  func testRebasePutsTheNearestTablePointOntoTodaysNearestPoint() {
    let lut = LensLut([
      LutPoint(meters: 1, steps: 300),
      LutPoint(meters: 3, steps: 5300),
    ], microsteps: 16)
    let delta = lutRebaseDelta(-200, lut)
    XCTAssertEqual(delta, -500)
    let rebased = lut.shifted(delta)
    XCTAssertEqual(rebased.points[0].steps, -200)
    // 平移不改变距离→步数的相对关系。
    XCTAssertEqual(rebased.stepsFor(2), lut.stepsFor(2)! - 500)
  }

  func testLensSurvivesAJsonRoundTrip() {
    let l = Lens(
      id: "a",
      name: "50mm",
      params: "F1.4",
      lut: LensLut([
        LutPoint(meters: 1, steps: 0),
        LutPoint(meters: 2, steps: 6400),
      ], microsteps: 32),
      strokeSteps: 8000,
      strokeMicrosteps: 32,
      dir: -1
    )
    guard let back = Lens(jsonObject: l.jsonObject) else {
      return XCTFail("round trip failed")
    }
    XCTAssertEqual(back, l)
  }

  func testWithoutStrokeClearsOnlyTheStroke() {
    let l = Lens(
      id: "a",
      name: "50mm",
      lut: LensLut([LutPoint(meters: 1, steps: 5)], microsteps: 16),
      strokeSteps: 8000,
      dir: -1
    )
    let cleared = l.withoutStroke()
    XCTAssertFalse(cleared.calibrated)
    // 防误触清空的是行程，方向和历史标定要留着，方便重标后接着用。
    XCTAssertEqual(cleared.dir, -1)
    XCTAssertEqual(cleared.lut.points.count, 1)
  }

  // MARK: - 存储

  func testStoreSavesAndReloadsFromDisk() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = LensStore(directory: dir)
    store.upsert(
      Lens(
        id: "a",
        name: "50mm F1.4",
        params: "F1.4",
        lut: LensLut([LutPoint(meters: 2, steps: 300)], microsteps: 16),
        strokeSteps: 6400,
        strokeMicrosteps: 16,
        dir: -1
      )
    )
    store.upsert(Lens(id: "b", name: "85mm"))
    try store.save()

    let back = LensStore.load(directory: dir)
    XCTAssertEqual(back.lenses.count, 2)
    XCTAssertEqual(back.lenses[0].name, "50mm F1.4")
    XCTAssertEqual(back.lenses[0].dir, -1)
    XCTAssertEqual(back.lenses[0].strokeAt(256), 102400)
    XCTAssertEqual(back.lenses[0].lut.points.count, 1)
    XCTAssertFalse(back.lenses[1].calibrated)
  }

  func testStoreUpsertReplacesByIDAndRemoveDrops() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = LensStore(directory: dir)
    store.upsert(Lens(id: "a", name: "旧"))
    store.upsert(Lens(id: "a", name: "新"))
    XCTAssertEqual(store.lenses.count, 1, "同一个 id 是替换而不是追加")
    XCTAssertEqual(store.lenses[0].name, "新")
    store.remove(id: "a")
    XCTAssertTrue(store.lenses.isEmpty)
  }

  func testStoreStartsEmptyWhenNothingWasSaved() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertTrue(LensStore.load(directory: dir).lenses.isEmpty)
  }

  func testCorruptStoreDoesNotCrash() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{{{ not json".utf8).write(to: dir.appendingPathComponent("lenses.json"))
    // 存档损坏应当当空列表处理，而不是把 App 弄崩。
    XCTAssertTrue(LensStore.load(directory: dir).lenses.isEmpty)
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ff-lens-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
