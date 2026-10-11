import XCTest

@testable import FollowFocusCore

/// 从 Dart 的 `test/lens_test.dart` 逐条搬过来，外加存储的落盘/迁移。
final class LensTests: XCTestCase {
  func testLensRoundTripSavesOnlyDirectionAndDistanceMap() {
    let lens = Lens(id: "a", name: "50mm", params: "F1.4",
      lut: LensLut([LutPoint(meters: 1, steps: 2000)]), dir: -1, directionConfirmed: true)
    XCTAssertEqual(Lens(jsonObject: lens.jsonObject), lens)
    for key in ["stroke", "strokeMs", "autoTravel", "autoSafeSpan", "autoFirmware"] {
      XCTAssertNil(lens.jsonObject[key])
    }
  }

  func testOldFm03AlignmentTableRequiresRecalibration() {
    let old: [String: Any] = ["id": "old", "name": "50mm", "dir": -1,
      "stroke": 4096, "autoTravel": 4096, "lut": ["points": [["m": 1, "s": 300]]]]
    let lens = Lens(jsonObject: old)!
    XCTAssertEqual(lens.name, "50mm")
    XCTAssertEqual(lens.dir, -1)
    XCTAssertFalse(lens.directionConfirmed)
    XCTAssertTrue(lens.lut.points.isEmpty)
    XCTAssertNil(lens.jsonObject["stroke"])
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
        lut: LensLut([LutPoint(meters: 2, steps: 300)]),
        dir: -1, directionConfirmed: true
      )
    )
    store.upsert(Lens(id: "b", name: "85mm"))
    try store.save()

    let back = LensStore.load(directory: dir)
    XCTAssertEqual(back.lenses.count, 2)
    XCTAssertEqual(back.lenses[0].name, "50mm F1.4")
    XCTAssertEqual(back.lenses[0].dir, -1)
    XCTAssertTrue(back.lenses[0].directionConfirmed)
    XCTAssertEqual(back.lenses[0].lut.points.count, 1)
    XCTAssertFalse(back.lenses[1].directionConfirmed)
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
    try Data("{{{ not json".utf8).write(to: dir.appendingPathComponent("lenses-fm03.json"))
    // 存档损坏应当当空列表处理，而不是把 App 弄崩。
    XCTAssertTrue(LensStore.load(directory: dir).lenses.isEmpty)
  }

  func testFm03StorePreservesButDoesNotImportOldStepCalibration() throws {
    let dir=try makeTempDir();defer { try? FileManager.default.removeItem(at:dir) }
    let old=dir.appendingPathComponent("lenses.json")
    let data=try JSONSerialization.data(withJSONObject:["lenses":[Lens(id:"old",name:"50mm").jsonObject]])
    try data.write(to:old)
    XCTAssertTrue(LensStore.load(directory:dir).lenses.isEmpty)
    XCTAssertEqual(try Data(contentsOf:old),data)
  }

  func testFivePointChartSurvivesColdStoreReload() throws {
    let directory = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lens = Lens(id: "full", name: "85mm", lut: LensLut([
      LutPoint(meters: 0.5, steps: 4096), LutPoint(meters: 1, steps: 3000),
      LutPoint(meters: 2, steps: 2000), LutPoint(meters: 3, steps: 1000),
      LutPoint(meters: 5, steps: 100)]), dir: -1, directionConfirmed: true)
    let store = LensStore(directory: directory)
    store.upsert(lens)
    try store.save()
    let restored = LensStore.load(directory: directory).lenses[0]
    XCTAssertEqual(restored, lens)
    XCTAssertTrue(restored.lut.ready)
    XCTAssertEqual(restored.lut.curve, lens.lut.curve)
    XCTAssertEqual(restored.lut.stepsFor(1.5), lens.lut.stepsFor(1.5))
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ff-lens-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
