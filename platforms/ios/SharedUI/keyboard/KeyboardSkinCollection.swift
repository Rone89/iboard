import UIKit

extension CustomKeyboardSkin {
  static var curatedTemplates: [(String, CustomKeyboardSkin)] {
    [
      // iOS 原生（Apple iOS 27 UI Kit 键盘官方取色，与 GlideKeyboard 的
      // IOS27_KEYBOARD_DESIGN.md 同源）：浅色面板 #E1E4E8、键帽 #FDFEFF、
      // 圆角 9（对齐 KeyboardKit Liquid Glass）、平面无投影无描边；深色面板 #1C1C1E、键帽为 17% 白叠层
      // （实测 #434344）。特殊键取 iOS 系统灰（浅 #AEAEB2、深 #2C2C2E），
      // 强调色为 iOS 蓝（浅色按 4.5:1 对比度要求加深为 #0A5DC8）。
      ("iOS 原生", {
        var skin = Self()
        skin.background = 0xE1E4E8
        skin.keyBackground = 0xFDFEFF
        skin.keyForeground = 0x000000
        skin.accent = 0x0A5DC8
        skin.actionBackground = 0xAEB3BC
        skin.cornerRadius = 9
        skin.borderWidth = 0
        skin.shadow = 0
        skin.pattern = 0
        skin.monospaced = false
        skin.keyShape = .rounded
        skin.keyMaterial = .flat
        skin.usesSystemBackdrop = true
        return skin
      }()),
      ("iOS 原生（深色）", {
        var skin = Self()
        skin.background = 0x1C1C1E
        skin.keyBackground = 0x434344
        skin.keyForeground = 0xFFFFFF
        skin.accent = 0x8CC2FF
        skin.actionBackground = 0x2C2C2E
        skin.cornerRadius = 9
        skin.borderWidth = 0
        skin.shadow = 0
        skin.pattern = 0
        skin.monospaced = false
        skin.keyShape = .rounded
        skin.keyMaterial = .flat
        skin.usesSystemBackdrop = true
        return skin
      }()),
      // 薄荷晨光（client-core 的 TouchKeyboardSkinDesign::mint_morning），曾是触屏键盘新装的默认皮肤。
      ("薄荷晨光", {
        var skin = Self()
        skin.background = 0xD8F0E4
        skin.keyBackground = 0xFAFFF9
        skin.keyForeground = 0x173D30
        skin.accent = 0x245A43
        skin.actionBackground = 0x245A43
        skin.cornerRadius = 14
        skin.borderWidth = 0.5
        skin.shadow = 0.08
        skin.pattern = 0
        skin.monospaced = false
        skin.gradientEnd = 0xEEF6DD
        skin.customBorderColor = 0xB6D8C5
        return skin
      }()),
      ("苔庭晨雾", {
        var skin = Self()
        skin.background = 0xE0E9DF
        skin.keyBackground = 0xF7FAF3
        skin.keyForeground = 0x243F32
        skin.accent = 0x214D3A
        skin.actionBackground = 0x2F6047
        skin.cornerRadius = 12
        skin.borderWidth = 0.5
        skin.shadow = 0.1
        skin.pattern = 3
        skin.monospaced = false
        skin.gradientEnd = 0xC6D9CA
        skin.gradientHorizontal = true
        skin.patternOpacity = 0.035
        skin.customBorderColor = 0xB8CDBE
        return skin
      }()),
      ("竹影青瓷", {
        var skin = Self()
        skin.background = 0xD9E8E2
        skin.keyBackground = 0xF5F8EE
        skin.keyForeground = 0x243F38
        skin.accent = 0x265443
        skin.actionBackground = 0x265443
        skin.cornerRadius = 4
        skin.borderWidth = 1
        skin.shadow = 0.04
        skin.pattern = 0
        skin.monospaced = false
        skin.gradientEnd = 0xEBF2E7
        skin.gradientHorizontal = true
        skin.patternOpacity = 0
        skin.customBorderColor = 0x94B4A3
        return skin
      }()),
      ("月下银砂", {
        var skin = Self()
        skin.background = 0x181F2B
        skin.keyBackground = 0x303E4F
        skin.keyForeground = 0xEFF5FC
        skin.accent = 0xCEE0F3
        skin.actionBackground = 0xCADBEC
        skin.cornerRadius = 10
        skin.borderWidth = 0.5
        skin.shadow = 0.08
        skin.pattern = 1
        skin.monospaced = false
        skin.gradientEnd = 0x283645
        skin.gradientHorizontal = true
        skin.patternOpacity = 0.07
        skin.customBorderColor = 0x6F8399
        return skin
      }()),
      ("黑金刻度", {
        var skin = Self()
        skin.background = 0x191B19
        skin.keyBackground = 0x292D29
        skin.keyForeground = 0xEFE9D5
        skin.accent = 0xE1CC91
        skin.actionBackground = 0xDAC486
        skin.cornerRadius = 3
        skin.borderWidth = 0.75
        skin.shadow = 0
        skin.pattern = 2
        skin.monospaced = true
        skin.gradientEnd = 0x202720
        skin.gradientHorizontal = true
        skin.patternOpacity = 0.04
        skin.customBorderColor = 0x8D8058
        return skin
      }()),
      ("樱雪糯米", {
        var skin = Self()
        skin.background = 0xF4DFE5
        skin.keyBackground = 0xFFF8F6
        skin.keyForeground = 0x503449
        skin.accent = 0x733E58
        skin.actionBackground = 0x904D69
        skin.cornerRadius = 18
        skin.borderWidth = 0
        skin.shadow = 0.14
        skin.pattern = 3
        skin.monospaced = false
        skin.gradientEnd = 0xE7E2F2
        skin.gradientHorizontal = true
        skin.patternOpacity = 0.04
        skin.customBorderColor = 0xDFBBC9
        return skin
      }()),
      ("落日陶土", {
        var skin = Self()
        skin.background = 0xEAD4C4
        skin.keyBackground = 0xFFF4DF
        skin.keyForeground = 0x56382C
        skin.accent = 0x733F2B
        skin.actionBackground = 0x9A4E32
        skin.cornerRadius = 7
        skin.borderWidth = 0.75
        skin.shadow = 0.18
        skin.pattern = 1
        skin.monospaced = false
        skin.gradientEnd = 0xF3E4D1
        skin.gradientHorizontal = true
        skin.patternOpacity = 0.05
        skin.customBorderColor = 0xCBA78D
        return skin
      }()),
      ("冰川薄荷", {
        var skin = Self()
        skin.background = 0xD9EBEA
        skin.keyBackground = 0xF5FFFF
        skin.keyForeground = 0x203E4B
        skin.accent = 0x275360
        skin.actionBackground = 0x34717C
        skin.cornerRadius = 14
        skin.borderWidth = 0.5
        skin.shadow = 0.06
        skin.pattern = 3
        skin.monospaced = false
        skin.gradientEnd = 0xDDE7F4
        skin.gradientHorizontal = true
        skin.patternOpacity = 0.035
        skin.customBorderColor = 0xC0DCDB
        return skin
      }()),
      ("奶咖手账", {
        var skin = Self()
        skin.background = 0xD9CFC0
        skin.keyBackground = 0xF6EFE2
        skin.keyForeground = 0x453B31
        skin.accent = 0x5A4630
        skin.actionBackground = 0x65523B
        skin.cornerRadius = 5
        skin.borderWidth = 1
        skin.shadow = 0.2
        skin.pattern = 2
        skin.monospaced = true
        skin.gradientEnd = 0xE8DFD0
        skin.gradientHorizontal = true
        skin.patternOpacity = 0.06
        skin.customBorderColor = 0xB09B83
        return skin
      }()),
    ]
  }
}
