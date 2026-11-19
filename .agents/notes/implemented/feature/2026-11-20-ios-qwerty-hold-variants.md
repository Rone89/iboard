# Agent Note: iOS 26 键字母键长按变体条（拼音声调与英文变音）

Status: implemented

## Problem

fork 的键盘面正按 iOS 原生逐块对齐（几何、数字层、皮肤已就位），但 26 键字母键的长按仍是「角标直出」：按住 0.5 秒直接输入 `LetterHintTable` 的符号（q→1…）。原生键盘的标志性长按交互——拼音键盘按住元音弹出 āáǎà、英文键盘弹出变音字母——没有入口，输入声调字母和带变音符号的西文在本键盘上做不到。

## Decision

26 键字母键按住满 `cornerHintHoldDelay`（0.5 秒）时，若当前语境在变体表内则弹出变体条 `KeyboardHoldVariantBar`：与放大气泡 `KeyPressPreviewView` 同层（键盘根视图）、同一套圆角阴影配色，条在气泡上方；滑动高亮所在变体、气泡跟随显示选中项，松手把选中的变体交给 `insertSymbolLayerLiteral` 字面上屏（先结束组字再写出）；滑回原键松手输入原字母；条外松手什么也不输入。沿设定方向滑动直出角标（`SwipeHintPolicy`）不受影响。

弹出语境由纯函数 `KeyboardLetterVariants.alphabet` 门控：只有**手机布局的拼音 26 键**（`.quanpin`、未画字母网格）给声调表、**英文 26 键**给变音表。双拼、九键、14/18 键字母网格、注音、韩文、粤拼、本地模式、iPad 一律不弹——这些语境的字母键各有自己的编码语义（字面变体会打错字），iPad 的原生键盘本就不弹长按变体（与 `KeyPressPreviewView` 只在手机上画一致）；不在表里的键长按照旧直出角标。

变体表：拼音 a/o/e/i/n 四声，u 附 ü 系四声，v 键把 ü 放在最前（v 本身就是 ü 的编码键）；英文按使用频率排常用变音字母。选择行为是字面上屏而非进组字：引擎组字只收 ASCII（`session` 的 `handle_character(value: u8)`），声调字母没有组合表示；英文模式同一条路走 `insertSymbolLayerLiteral` 的英文分支（`insertDirectText`）。

实现落点：`KeyboardHoldVariantBar.swift`（新文件：变体表、门控、条视图）、`KeyboardKeyButton`（`holdVariants` / `onHoldVariant` 属性、与角标共用同一条按住计时、`continueTracking` / `touchesMoved` / `touchesEnded` / `touchesCancelled` 各加一条变体分支）、`KeyboardViewController`（`makeLetterRow` 挂输入回调、`updateLetterCaseControls` 按模式设表；`LetterCaseInputs` 增加 `letterGridShown` 字段，防止 26 键与 14/18 键网格互切时键面更新被相等性短路跳过）。

## Alternatives considered

- **复用九键长按的 `showKeyHoldOptions`（UIMenu）**：现成组件、改动最小；但 UIMenu 是系统上下文菜单形态（按下等菜单弹出、松手才选中，无滑动跟随高亮），与原生键盘「按住即出条、滑动跟随、松手选中」的手感完全不同，样式也不是键盘放大气泡的语言，放弃。
- **声调字母折回基础字母进组字**：拼音输入流不中断，更接近原生 IME 对声调的处理；但引擎收不到声调信息，预编辑里出现的仍是基础字母，「选中 ā 却看到 a」的可感知不一致比打断组字更糟，放弃。引擎将来支持声调字母后可重议这条。
- **所有字母键长按都弹条（含无变体的声母）**：交互统一，但声母弹一条空的是负反馈，原生键盘对无变体的键也不弹；声母键长按维持角标直出，滑动直出角标在所有键上保留。

## Consequences

收益：拼音键盘有了打出 āáǎà 与 ü 的入口，英文模式可打出变音西文；26 键长按手感与 iOS 原生一致，是键盘照原生对齐的又一块。

代价：拼音 26 键与英文 26 键的字母键长按不再直出角标（0.5 秒按住 q→1 的旧习惯在这两个语境改为弹条，滑动直出角标不变，其余语境不受影响）；变体条接管期间跳过 `UIControl` 自身的跟踪更新（高亮由变体分支手动保持），角标滑动与九键滑动的判定路径各加了一条前置分支。

验证：`KeyboardHoldVariantsTests` 钉住变体表内容、门控纯函数、条的几何（居中、压边、压矮、无空间不出条）与选中判定；模拟器真跑键盘的长按截图随 PR 提交。
