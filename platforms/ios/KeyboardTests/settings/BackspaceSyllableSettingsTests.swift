import XCTest

/// 「按音节回删」保存到共享文档并在 App Group 留镜像：文档先落地、镜像随后（save 返回 false 时镜像不动）；文档没有的键或值不是布尔时按关读，与 client-core 的缺省一致。
final class BackspaceSyllableSettingsTests: XCTestCase {
  private var state: URL!
  private var previous = false

  override func setUp() {
    super.setUp()
    state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-backspace-syllable-settings-\(UUID().uuidString)", isDirectory: true)
    previous = TouchBackspaceSyllablePreference.isEnabled
  }

  override func tearDown() {
    TouchBackspaceSyllablePreference.isEnabled = previous
    try? FileManager.default.removeItem(at: state)
    super.tearDown()
  }

  func testSaveWritesTheDocumentKeyAndMirrorsLocally() throws {
    _ = MetasequoiaInputSessionBridge(stateRoot: state)

    XCTAssertTrue(TouchBackspaceSyllablePreference.save(true, stateRoot: state))
    XCTAssertTrue(TouchBackspaceSyllablePreference.isEnabled)
    let document = try XCTUnwrap(MetasequoiaInputSessionBridge.loadSharedPreferences(stateRoot: state))
    XCTAssertEqual(document["touch_backspace_by_syllable"] as? Bool, true)

    XCTAssertTrue(TouchBackspaceSyllablePreference.save(false, stateRoot: state))
    XCTAssertFalse(TouchBackspaceSyllablePreference.isEnabled)
    let updated = try XCTUnwrap(MetasequoiaInputSessionBridge.loadSharedPreferences(stateRoot: state))
    // Rust 的默认值不写进文档（skip_serializing_if）：显式写 false 落盘时被省掉，缺键按关读。
    XCTAssertNil(updated["touch_backspace_by_syllable"])
    XCTAssertFalse(TouchBackspaceSyllablePreference.isEnabled(in: updated))
  }

  func testMirrorCopiesTheDocumentIntoTheAppGroup() {
    TouchBackspaceSyllablePreference.isEnabled = false
    TouchBackspaceSyllablePreference.mirror(["touch_backspace_by_syllable": true])
    XCTAssertTrue(TouchBackspaceSyllablePreference.isEnabled)
    TouchBackspaceSyllablePreference.mirror([:])
    XCTAssertFalse(TouchBackspaceSyllablePreference.isEnabled, "文档没记时镜像回到默认关")
    // 文档缺失时不动镜像：与 TouchShuangpinLayoutPreference.mirror 的口径一致。
    TouchBackspaceSyllablePreference.isEnabled = true
    TouchBackspaceSyllablePreference.mirror(nil)
    XCTAssertTrue(TouchBackspaceSyllablePreference.isEnabled)
  }

  func testUnknownOrMissingValuesReadAsOff() {
    XCTAssertFalse(TouchBackspaceSyllablePreference.isEnabled(in: nil))
    XCTAssertFalse(TouchBackspaceSyllablePreference.isEnabled(in: [:]))
    XCTAssertFalse(TouchBackspaceSyllablePreference.isEnabled(in: ["touch_backspace_by_syllable": "打开"]))
  }
}
