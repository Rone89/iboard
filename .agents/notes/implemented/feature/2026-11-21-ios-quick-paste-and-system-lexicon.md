# Agent Note: iOS 工具栏一键粘贴胶囊与系统自定义短语接入

Status: implemented

## Problem

1. **复制后需点开剪贴板面板才能粘贴**：用户刚复制验证码、链接或图片后切回键盘，仍要先点剪贴板图标再选中首条，操作多一步；但若每次键盘出现都直接读取 `UIPasteboard.general.string`，又会在同一条剪贴板内容上反复触发系统粘贴权限横幅。
2. **系统「设置 › 通用 › 键盘 › 文本替换」自定义短语未生效**：许多 iOS 用户已在系统键盘维护了邮箱、地址等缩写短语，第三方键盘若不调用 `requestSupplementaryLexicon`，这些短语在中文拼音与英文输入中完全不可见。

## Decision

1. **一键粘贴胶囊（[QuickPasteToolbar.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/QuickPasteToolbar.swift)）**：
   - 新增 `QuickPasteToolbarPolicy` 与 `QuickPasteToolbarButton`，放在工具栏品牌键右侧、spacer 左侧；仅在 `UIPasteboard.general.changeCount > 0` 且 `hasStrings || hasImages` 且 `changeCount` 未被标记已处理（`toolbar.quickPaste.handledChangeCount`）时显示。
   - 按 `changeCount` 缓存文本摘要（合并换行取前 5 字加省略号）或图片缩略图，避免同一内容重复读取剪贴板；点击文本直接上屏，点击图片保留剪贴板内容并提示长按输入框粘贴，随后记录 `handledChangeCount` 并隐藏按钮。
   - 该按钮为按需出现的临时胶囊，不纳入工具栏长按进入「编辑工具栏」的固定按钮集合。
2. **系统自定义短语（[SystemLexiconStore.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/SystemLexiconStore.swift)）**：
   - 在 `KeyboardViewController` 中通过 `requestSupplementaryLexicon` 异步加载并缓存系统短语条目，过滤空项与 `userInput == documentText` 的无意义项。
   - 匹配时忽略大小写与拼音分词撇号 `'`，在中/英文候选渲染和空格提交路径中将匹配到的系统短语优先插入候选前排，不修改共享 Rust 词库契约。

## Alternatives considered

- **把一键粘贴做成常驻工具栏开关按钮**：用户未复制新内容时占住工具栏宽度，320pt 窄屏会挤占现有按钮空间；按 `changeCount` 出现并在粘贴后自动收起更省空间。
- **在 Rust 引擎里导入系统短语**：`UILexicon` 仅在 iOS 键盘扩展运行时由 `UIInputViewController` 提供，且会随系统设置动态变化，放在 iOS 扩展层内存缓存并参与候选合并最轻量。

## Consequences

- **收益**：刚复制的文本/图片可在工具栏一键触达且不重复打扰；用户原有的 iOS 系统文本替换短语在中文与英文输入下立即可用。
- **代价**：`NineKeyKeyboardTests.testLongPressOnAnyToolbarButtonOpensTheToolbarEditor` 同步调整为排除瞬态 `quickPasteShortcut` 后断言其余 14 个工具栏按钮的长按行为。
- **验证**：由 `pnpm run verify-notes`、`KeyboardKitParityEnhancementTests` 与 `NineKeyKeyboardTests` 在 iOS 模拟器上覆盖验证。
