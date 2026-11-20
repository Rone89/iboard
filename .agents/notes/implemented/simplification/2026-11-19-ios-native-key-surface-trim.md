# Agent Note: iBoard 键盘面照 iOS 原生收紧（⇧ 恒定、数字层 4×3、工具栏去 符）

Status: implemented

## Problem

fork 把键盘几何对齐到 iOS 27 系统键盘、皮肤做了 iOS 原生款之后，键面上还留着三处与 iOS 原生不一致、对 fork 所有者（唯一用户）没有价值的设计：

1. 全拼 26 键在共享偏好 `touch_quanpin_shift` 为 `false` 时，第三排左端把 ⇧ 换成「分词」文字键——fork 所有者的设备上恰好是关着的，看起来就不是 iOS 键盘。
2. 数字九宫格（123 层，所有键面的数字入口）是「左栏运算符＋3×3 网格＋右列 ⌫/. /!＋底行 符|返回|0|空格|中|回车」的设计稿排法，与 iOS 原生数字键盘的 4×3（1–9 加 空位|0|⌫）完全不同。
3. 26 键「长空格」样式把 符 挪到工具栏（候选栏位置），空闲工具栏上多出一个 符 按钮。

## Decision

三条都是减法，落在 iOS 一端；共享偏好与 Android/鸿蒙不动：

- **26 键第三排左端恒为 ⇧**：删除 `usesQuanpinSeparator` 及 `quanpinShiftEnabled` 的读取与同步分支（`KeyboardViewController.swift`），`handleLetterShift` 恒走大小写切换（中文模式点它临时切英文，组字中臂辅助码），`styleShiftKeys` 恒画箭头图标。iOS 设置页删除「组字时保留 Shift」开关，`KeyboardLayoutPreference` 的 `quanpinShift`/`saveQuanpinShift`/`sharedQuanpinShift` 一并删除。共享文档里的 `touch_quanpin_shift` 保留原样（Android/鸿蒙继续用），iOS 不再读它。九键右列中间键、14/18 键第三排左端的分词键不受影响。热力图的 26 键默认布局把该格改画 ⇧（记 `ShiftLeft`）。取代 [组字时保留 Shift 的共享偏好](../feature/2026-10-26-touch-quanpin-shift-preference.md) 与 [移动端 26 键默认保留 Shift](../feature/2026-10-31-mobile-pinyin-26-key-shift.md) 的 iOS 部分。
- **数字层照 iOS 原生排 4×3**：`styleTableRow` 对一切数字层（九键一族自己的、笔画、以及从 26 键/英文/其他键面借来的数字九宫格）返回新表 `TouchBottomRowLayout.numberPadNative(globe:)`——返回 |（🌐）| 0 | ⌫ 等宽，与网格三列对齐，底行高度即网格排高，键盘总高不变。左栏（运算符、#+=、符）和右列（⌫、中点、！）在数字层整体隐藏，空格、中/英、回车不再出现在数字层；`touch_number_pad_space`（空格位置）与九键「右侧大回车」的数字层排法随之在 iOS 退场。小数点挂在 0 的长按上（`handleDigitPadZeroHold`，与 Gboard 的 0 长按一致）；符号面板从字母层 123 的长按（读屏自定义动作）和功能菜单进。取代 [触屏按键布局样式](../feature/2026-10-27-touch-key-layout-styles.md) 与 [#10061 数字层底行](../bug-fix/2026-10-29-mobile-number-pad-entry-position.md)、[#10061/#9113 符与切换键同格](../feature/2026-10-29-touch-symbol-first-and-number-pad-space.md) 中数字层部分的 iOS 行为。
- **工具栏去 符**：删除 `symbolsShortcut`、`toolbarSymbolsEntryShown`、`toolbarRowKept`、`longSpaceToolbarRowKept` 与 `updateToolbarSymbolsEntry`，「长空格」样式只剩底行长空格与 #+= 层逗号两个特征；工具栏空闲内容与 Android 的 `toolbarRowHidden` 同义，`KeyboardPreviewToolbarItem.symbols` 一并删除。符号面板入口只剩字母层 123 长按与功能菜单。

## Alternatives considered

- **保留左栏和右列、只把网格排成原生 4×3**：保住运算符、#+=、句点、！和空格的数字层入口，测试改动最小；但侧栏加右列占掉整宽 28%，中间网格与原生观感差距仍大，「参考 iOS 原生」等于没做，放弃。
- **只翻转 `touch_quanpin_shift` 默认值**：一行改动，但该偏好 iOS 侧已无存在意义（默认开、开着就是 ⇧），留着开关只会让设置页多一个无效项；iOS 直接退役更干净。Android/鸿蒙的默认值与开关不动。
- **数字层保留右侧栏的 ASCII 符号追加（半角语境的 @ : ; ' 等）**：藏文组字中的 achung（`'`）与英文数字层的 `!` 目前只剩符号面板（面板会先上屏组字，组字中不可用），这是本次最大的功能损失；把符号做成 0 长按菜单是候选后续，但一个长按挂五个符号发现性太差，先接受损失、由数字键盘的原生形态换。

## Consequences

收益：26 键与数字层的键面与 iOS 原生一致，长空格样式的工具栏不再有符号按钮；数字层键盘总高不变（三排网格＋底行 == 原生四排），布局代码删掉数字页专用的四组宽度约束、`borrowedNumberPadWidths`、`numberPadColumnSpace` 与数字侧栏的可见性分支约两百行。

代价与边界：

- 数字层不再能输入 运算符、`!`、空格，中/英与回车也不在数字层；输入这些字符要回字母层或符号面板（面板会先结束组字）。
- **藏文组字中的 achung（`'`）在键盘上没有 UI 入口了**：原来走数字侧栏的半角追加符号，现在字母层（威利字母键）和数字层（原生底排）都画不出 `'`，组字中途收 `'`（`dga'`）只能靠引擎层路径。这是已知缺口，后续若需要，候选方案是给藏文字母面加 `'` 键或给原生底排挂拼写符号长按菜单。
- #+= 内联符号层（设计稿的符号页）在键盘上没有入口了（原来从数字层左栏进），只有大千 #+= 的共享符号行和 `SymbolLayerLayout` 的画法保留在代码里；符号面板覆盖了它的用途。
- `touch_quanpin_shift`、`touch_number_pad_space`、`touch_nine_key_digit_sidebar_symbols` 三个共享键 iOS 不再消费；Android/鸿蒙行为不变。共享偏好本身不清，避免影响账号同步的其他端。
- 统计热力图与设置页预览的 26 键默认图把该格画成 ⇧（`ShiftLeft`）；「数字键盘」设置组的空格位置胶囊与数字层符号表编辑器随功能一起从 iOS 设置页移除。

## Testing

- `xcodebuild -workspace MSIMEClient.xcworkspace -scheme MSIMEClientTests`：MSIMEKeyboardTests 全套（1261 例）通过 1229 例；余下失败均为本机环境的既有问题（AppLauncher 的 URL scheme 断言停留在 fork 改名前的 `msime`、主题/画布类用例吃到未提交的主题硬重置改动），与本笔记的改动无关。
- 更新的用例：`KeyLayoutStyleTests` 的数字层底排（`numberPadNative` 表、右栏隐藏、长空格数字层、语言键侧偏好对数字层无效）、`NineKeyKeyboardTests` 的 `checkNumberPad`/键高/底行宽度/工具栏计数、`KeyboardFormFactorTests` 的 iPad 数字层、`TouchToolbarPreferenceTests` 的预览表、藏文组字跨数字层存活；删除的用例：分词替换（`testQuanpinSeparator*`）、数字空格位置（`testNumberPadSpacePositions*`、右列空格盖板）、数字层撇号（`testTibetanNumberPadApostrophe*`）。
- 模拟器验收：iPhone 18 Pro Max 安装新构建，截图 26 键（⇧）、数字层（原生 4×3）、长空格工具栏（无 符）与改动前对照。
