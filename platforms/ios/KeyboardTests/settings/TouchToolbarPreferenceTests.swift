import XCTest

/// 工具栏按钮 read from the shared `touch_toolbar`.
final class TouchToolbarPreferenceTests: XCTestCase {
  func testAnUntouchedDocumentKeepsTheBarTheKeyboardAlwaysHad() {
    for preferences in [nil, [:], ["touch_toolbar": "not an object"]] as [[String: Any]?] {
      XCTAssertEqual(TouchToolbarPreference(in: preferences), TouchToolbarPreference())
    }
    let defaults = TouchToolbarPreference()
    XCTAssertTrue(defaults.layout && defaults.emoji && defaults.skin)
    XCTAssertFalse(defaults.clipboard || defaults.ai || defaults.characterSet || defaults.fullwidth || defaults.punctuation)
  }

  func testStoredSwitchesWinAndMissingOnesKeepTheirDefault() {
    let pinned = TouchToolbarPreference(in: ["touch_toolbar": [
      "skin": false, "clipboard": true, "character_set": true, "punctuation": "yes",
    ]])
    XCTAssertFalse(pinned.skin)
    XCTAssertTrue(pinned.clipboard)
    XCTAssertTrue(pinned.characterSet)
    XCTAssertTrue(pinned.layout, "absent, so on by default")
    XCTAssertFalse(pinned.punctuation, "a value that is not a Bool reads as the default")
  }

  func testTheNativePageWritesTheWholeObjectTheSharedValidatorAccepts() throws {
    let state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-toolbar-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    _ = MetasequoiaInputSessionBridge(stateRoot: state)
    XCTAssertEqual(TouchToolbarPreference.load(stateRoot: state), TouchToolbarPreference())

    var toolbar = TouchToolbarPreference()
    toolbar.skin = false
    toolbar.clipboard = true
    toolbar.punctuation = true
    XCTAssertTrue(TouchToolbarPreference.save(toolbar, stateRoot: state))
    XCTAssertEqual(TouchToolbarPreference.load(stateRoot: state), toolbar)
    let stored = try XCTUnwrap(
      MetasequoiaInputSessionBridge.loadSharedPreferences(stateRoot: state)?["touch_toolbar"] as? [String: Any])
    XCTAssertEqual(Set(stored.keys), Set(TouchToolbarPreference.options.map(\.name)))
  }

  /// 常用语、输入方式 和 显示方式 属于本设备自己的设置，默认值与 Android 的本地设置一致：两个按钮都打开，输入时显示工具栏。
  func testTheLocalSwitchesKeepAndroidsDefaults() {
    let defaults = TouchToolbarLocalPreference.defaults
    let keys = TouchToolbarLocalPreference.keys
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
    keys.forEach(defaults.removeObject(forKey:))
    XCTAssertTrue(TouchToolbarLocalPreference.phrases)
    XCTAssertTrue(TouchToolbarLocalPreference.scheme)
    XCTAssertFalse(TouchToolbarLocalPreference.hidden)
    TouchToolbarLocalPreference.hidden = true
    TouchToolbarLocalPreference.scheme = false
    XCTAssertEqual(defaults.object(forKey: "keyboard.toolbar.hidden") as? Bool, true)
    XCTAssertEqual(defaults.object(forKey: "keyboard.toolbar.scheme") as? Bool, false)
    XCTAssertTrue(TouchToolbarLocalPreference.hidden)
    XCTAssertFalse(TouchToolbarLocalPreference.scheme)
    defaults.set("yes", forKey: TouchToolbarLocalPreference.phrasesKey)
    XCTAssertTrue(TouchToolbarLocalPreference.phrases, "a value that is not a Bool reads as the default")
  }

  // MARK: - 「键盘工具栏」设置页的预览

  /// 预览按键盘绘制顺序列出打开的工具：表情、常用语、皮肤，然后是 iOS 独有项。工具栏上没有 符（符号面板从长按 123 和功能菜单进）。
  func testThePreviewListsTheEnabledToolsInDrawingOrder() {
    let toolbar = TouchToolbarPreference()
    for style in TouchTwentySixKeyStyle.allCases {
      let items = KeyboardToolbarPreviewRow.items(toolbar, phrases: true, scheme: false, hidden: false,
                                                  keyLayout: TouchKeyLayoutStyle(twentySixKey: style))
      XCTAssertEqual(items, [.emoji, .phrases, .skin], style.rawValue)
    }
  }

  /// 显示方式为「隐藏」或可选按钮全关时，预览不画工具栏内容（nil，只留顶栏高度），与键盘的 `toolbarRowHidden` 相同。
  func testTheHiddenRowDrawsNoToolbarContent() {
    var none = TouchToolbarPreference()
    for option in TouchToolbarPreference.options { none[keyPath: option.keyPath] = false }
    let standard = TouchKeyLayoutStyle()
    let longSpace = TouchKeyLayoutStyle(twentySixKey: .longSpace)
    func items(_ toolbar: TouchToolbarPreference, hidden: Bool,
               _ style: TouchKeyLayoutStyle) -> [KeyboardPreviewToolbarItem]? {
      KeyboardToolbarPreviewRow.items(toolbar, phrases: false, scheme: false, hidden: hidden, keyLayout: style)
    }
    XCTAssertNil(items(TouchToolbarPreference(), hidden: true, standard), "a hidden toolbar draws no content")
    XCTAssertNil(items(none, hidden: false, standard), "nothing but the logo and the collapse button")
    XCTAssertNil(items(TouchToolbarPreference(), hidden: true, longSpace), "hidden keeps only the logo and the collapse button")
    XCTAssertNil(items(none, hidden: false, longSpace))
    XCTAssertNil(KeyboardToolbarPreviewRow.items(TouchToolbarPreference(), phrases: true, scheme: true, hidden: true,
                                                 keyLayout: longSpace), "hiding drops every optional button, local ones included")
  }
}
