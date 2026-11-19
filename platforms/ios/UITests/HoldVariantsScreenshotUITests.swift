import XCTest

/// 长按变体条的验收截图：把水杉键盘切到测试宿主的编辑器上，长按 26 键的 A，
/// 在条弹出的窗口里截屏。弹出条只存在于手指按住期间，所以长按进行中由后台队列延时截屏；
/// 模拟器进程与宿主共享文件系统，截图写到绝对路径由宿主直接取走。
final class HoldVariantsScreenshotUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// `path` 是截图要写的绝对路径，`key` 是要长按的字母键（读屏标签为大写），截屏安排在长按进行中。
  private func captureHoldVariant(to path: String, key: String, hold: TimeInterval, captureAfter: TimeInterval) throws {
    let editor = XCUIApplication(bundleIdentifier: "app.msime.ios.keyboard-test-host")
    editor.launchArguments = ["--system-keyboard-editor"]
    editor.launch()
    let field = editor.textFields["systemKeyboardEditor"]
    XCTAssertTrue(field.waitForExistence(timeout: 15), "测试宿主的编辑器必须出现")
    let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
    if XCTWaiter.wait(for: [focused], timeout: 10) != .completed { field.tap() }

    // 当前不是水杉时，长按地球键从系统键盘列表里选（与 KeyboardExtensionEditorUITests 同一条路）。
    if editor.buttons["moreShortcut"].waitForExistence(timeout: 5) == false {
      let globe = editor.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘"])).firstMatch
      XCTAssertTrue(globe.waitForExistence(timeout: 6), "系统键盘上必须有地球键")
      globe.press(forDuration: 1)
      let ours = editor.descendants(matching: .any)
        .matching(NSPredicate(format: "label BEGINSWITH %@", "水杉输入法")).firstMatch
      XCTAssertTrue(ours.waitForExistence(timeout: 5), "系统键盘列表里必须有水杉输入法——先在设置里启用")
      ours.tap()
      XCTAssertTrue(editor.buttons["moreShortcut"].waitForExistence(timeout: 8), "切到水杉键盘后品牌按钮必须出现")
    }

    // 中文 26 键的字母键：键面画大写，读屏标签也是大写。
    let target = editor.buttons[key]
    XCTAssertTrue(target.waitForExistence(timeout: 6), "水杉 26 键上必须有 \(key) 键")

    let captured = XCTestExpectation(description: "截图落盘")
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + captureAfter) {
      let image = XCUIScreen.main.screenshot()
      do {
        try image.pngRepresentation.write(to: URL(fileURLWithPath: path))
        captured.fulfill()
      } catch {
        XCTFail("截图写不进 \(path)：\(error)")
      }
    }
    target.press(forDuration: hold)
    wait(for: [captured], timeout: 10)
    editor.terminate()
  }

  /// 改动后：条弹出期间截屏。
  func testCaptureHoldVariantPopup() throws {
    try captureHoldVariant(to: "/tmp/hold-variants-after.png", key: "A", hold: 1.5, captureAfter: 1.0)
  }

  /// 改动前对照：长按无变体的 B 走的就是本次未改动的旧路径（0.5 秒后角标直出、只有放大气泡），
  /// 与改动前长按任何字母键的表现相同——「改前」的图由它充当，不需要另装旧包。
  func testCaptureHoldKeepsTheCornerHintPath() throws {
    try captureHoldVariant(to: "/tmp/hold-variants-before.png", key: "B", hold: 1.5, captureAfter: 1.0)
  }
}
