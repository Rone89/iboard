import SwiftUI

/// 表达：输入的文字如何输出，对应 Android 的 `ExpressionPage`。标点分组放三个日常标点开关，其余规则在标点页，点一行就到；智能分组放整句联想、上屏后联想及其联想栏按键、英文联想；常用语打开键盘常用语面板发送的那些短语。
///
/// 标点开关、整句联想和上屏后联想读写共享偏好文档，键盘下次出现时应用。英文联想沿用 App Group 开关（`EnglishSuggestionsPreference`），控制原文及唯一纠错候选和空格默认纠错；不增加第二个开关。
struct ExpressionSettingsView: View {
  @AppStorage(EnglishSuggestionsPreference.enabledKey, store: EnglishSuggestionsPreference.defaults)
  private var englishSuggestions = true
  @ObservedObject private var resourcePacks = IOSResourcePackStore.shared
  @State private var chinesePunctuation = true
  @State private var paired = true
  @State private var smart = true
  @State private var lock = "follow"
  @State private var sentenceLevel = SentenceAssociationPreference.Level.enhanced
  @State private var grammarModel = SentenceAssociationPreference.GrammarModel.baguwenCompact
  @State private var nextWordPrediction = false
  @State private var predictionButtons = NextWordPredictionButtons.expandOnly
  @State private var failedGroup: PageGroup?

  private enum PageGroup { case punctuation, intelligence }

  private static let sentenceSubtitle = "更准确，但更耗电"
  private static let grammarSubtitle = "借助词语搭配概率提升长句和九宫格选词准确度；内置八股文紧凑版离线可用，也可按需下载万象 LTS 大模型"
  private static let predictionInfo = "选词上屏后推荐后续文字，点选、按数字键或空格上屏，继续输入其他内容时消失；使用现有词库，开启学习时也参考个人词序，隐私输入不显示"
  private static let predictionButtonsInfo = "联想出现时候选栏右端的按键：× 关闭联想，不输入任何字符；∨ 展开更多联想。只有关闭时左右滑动候选栏选词"

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        DesignGroup(title: "标点", footer: failedGroup == .punctuation ? SettingsSaveFailure.message : nil) {
          DesignToggleRow(title: "使用英文标点", subtitle: lockSubtitle, isOn: englishPunctuation)
            .disabled(lock != "follow")
            .accessibilityIdentifier("englishPunctuationToggle")
          DesignDivider()
          DesignToggleRow(title: "自动补全成对标点", info: "输入左侧括号或引号时同时补上右侧",
                          isOn: stored("paired_punctuation", $paired, group: .punctuation))
            .accessibilityIdentifier("pairedPunctuationToggle")
          DesignDivider()
          DesignToggleRow(title: "智能标点", info: "字母或数字后的 , . : 使用英文标点",
                          isOn: stored("smart_punctuation", $smart, group: .punctuation))
            .accessibilityIdentifier("smartPunctuationToggle")
          DesignDivider()
          NavigationLink(destination: PunctuationSettingsView()) {
            DesignNavRowLabel(title: "更多标点设置", info: "引号与括号样式、固定标点、全角输入、中英文空格和智能标点细则")
          }
          .buttonStyle(PressFillButtonStyle())
          .accessibilityIdentifier("punctuationSettingsLink")
        }

        DesignGroup(title: "智能", footer: failedGroup == .intelligence ? SettingsSaveFailure.message : nil) {
          DesignSelectRow(title: "整句联想", info: Self.sentenceSubtitle,
                          options: SentenceAssociationPreference.Level.allCases.map { DesignOption(title: $0.title, value: $0) },
                          selection: Binding(get: { sentenceLevel }, set: saveSentenceLevel),
                          sheetTitle: "整句联想", sheetMessage: Self.sentenceSubtitle,
                          identifier: "sentenceAssociationPicker")
          DesignDivider()
          DesignSelectRow(title: "语法模型", info: Self.grammarSubtitle, enabled: sentenceLevel != .off,
                          options: SentenceAssociationPreference.GrammarModel.allCases.map { DesignOption(title: $0.title, value: $0) },
                          selection: Binding(get: { grammarModel }, set: saveGrammarModel),
                          sheetTitle: "语法模型", sheetMessage: Self.grammarSubtitle,
                          identifier: "grammarModelPicker")
          if shouldShowWanxiangManageRow {
            DesignDivider()
            wanxiangGrammarManageRow
          }
          DesignDivider()
          DesignToggleRow(title: "上屏后联想", info: Self.predictionInfo,
                          isOn: stored(NextWordPredictionButtons.enabledKey, $nextWordPrediction, group: .intelligence))
            .accessibilityIdentifier("nextWordPredictionToggle")
          DesignDivider()
          // 联想按键的样式只在开启上屏后联想后可选，关着时整行变灰，与 Android 一样；用 `enabled` 而不是 `.disabled`，「?」仍能点开。
          DesignSelectRow(title: "联想栏按键", info: Self.predictionButtonsInfo, enabled: nextWordPrediction,
                          options: NextWordPredictionButtons.allCases.map { DesignOption(title: $0.title, value: $0) },
                          selection: SharedPreferenceBinding.custom(state: $predictionButtons, onSave: { record($0, group: .intelligence) }) {
                            $0[NextWordPredictionButtons.documentKey] = $1.rawValue
                          },
                          sheetTitle: "联想栏按键", sheetMessage: Self.predictionButtonsInfo,
                          identifier: "nextWordPredictionButtonsPicker")
          DesignDivider()
          DesignToggleRow(title: "英文联想", info: "保留原文并提供纠错，空格默认采用纠错结果", isOn: $englishSuggestions)
            .accessibilityIdentifier("englishSuggestionsToggle")
        }

        DesignGroup(title: "常用语", info: "在键盘的「常用语」面板中，点一下即可发送") {
          NavigationLink(destination: CommonPhrasesSettingsView()) {
            DesignNavRowLabel(title: "常用语")
          }
          .buttonStyle(PressFillButtonStyle())
          .accessibilityIdentifier(SettingsPage.phrases.linkIdentifier)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 32)
    }
    .designCanvasBackground()
    .navigationTitle("表达")
    .navigationBarTitleDisplayMode(.inline)
    .reloadOnAppearAndActive(reload)
    .alert("下载语法模型", isPresented: Binding(
      get: { resourcePacks.meteredRequest == SentenceAssociationPreference.wanxiangGrammarPackID },
      set: { if !$0 { resourcePacks.meteredRequest = nil } }), presenting: resourcePacks.meteredRequest) { id in
        Button("下载") { resourcePacks.start(id) }
        Button("取消", role: .cancel) { resourcePacks.meteredRequest = nil }
      } message: { id in
        Text("当前网络按流量计费或开启了低数据模式，模型大小约 \(resourcePacks.size(id))。是否继续？")
      }
  }

  private var wanxiangPackID: String { SentenceAssociationPreference.wanxiangGrammarPackID }

  private var shouldShowWanxiangManageRow: Bool {
    sentenceLevel != .off
      || grammarModel == .wanxiang
      || resourcePacks.available(wanxiangPackID)
      || resourcePacks.statuses[wanxiangPackID] != nil
  }

  private var wanxiangGrammarManageRow: some View {
    let status = resourcePacks.statuses[wanxiangPackID]
    let installed = resourcePacks.available(wanxiangPackID)
    let running = status?.running == true
    let subtitle: String = {
      if let status { return status.message }
      if installed {
        return grammarModel == .wanxiang ? "已下载 · 当前已启用，重开键盘生效" : "已下载 · 可在上方切换启用"
      }
      if grammarModel == .wanxiang {
        return "未下载（\(resourcePacks.size(wanxiangPackID))），下载完成前暂用内置八股文紧凑版"
      }
      return "约 \(resourcePacks.size(wanxiangPackID)) · 更大词库搭配覆盖，下载后自动切换"
    }()
    return Button {
      if running {
        resourcePacks.cancel(wanxiangPackID)
      } else if installed {
        resourcePacks.remove(wanxiangPackID)
        if grammarModel == .wanxiang {
          saveGrammarModel(.baguwenCompact)
        }
      } else {
        if grammarModel != .wanxiang {
          saveGrammarModel(.wanxiang)
        } else {
          resourcePacks.request(wanxiangPackID)
        }
      }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("万象 LTS 语法模型").foregroundStyle(.primary)
          Text(subtitle).font(.system(size: 13)).foregroundStyle(MetasequoiaTheme.sub)
        }
        Spacer()
        Text(running ? "取消" : (installed ? "删除" : "下载"))
          .foregroundStyle(installed && !running ? Color.red : MetasequoiaTheme.accent)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(PressFillButtonStyle())
    .accessibilityIdentifier("wanxiangGrammarManageRow")
  }

  /// 使用英文标点是 `chinese_punctuation` 取反。`punctuation_lock` 不是跟随时，键盘里以它为准，此时开关显示锁定后的形式，不能在这里改。
  private var englishPunctuation: Binding<Bool> {
    Binding(get: {
      switch lock {
      case "chinese": false
      case "english": true
      default: !chinesePunctuation
      }
    }, set: { english in
      stored("chinese_punctuation", $chinesePunctuation, group: .punctuation).wrappedValue = !english
    })
  }

  private var lockSubtitle: String? {
    switch lock {
    case "chinese": "已锁定为中文标点"
    case "english": "已锁定为英文标点"
    default: nil
    }
  }

  /// 随改动写入共享文档某个顶层字段的绑定；写入被拒绝时恢复已存的值，让页面永远不会显示键盘实际没有的设置。
  private func stored(_ key: String, _ state: Binding<Bool>, group: PageGroup) -> Binding<Bool> {
    SharedPreferenceBinding.topLevel(key, state: state) { saved in record(saved, group: group) }
  }

  private func saveSentenceLevel(_ level: SentenceAssociationPreference.Level) {
    guard level != sentenceLevel else { return }
    sentenceLevel = level
    record(SentenceAssociationPreference.save(level), group: .intelligence)
  }

  private func saveGrammarModel(_ model: SentenceAssociationPreference.GrammarModel) {
    guard model != grammarModel else { return }
    grammarModel = model
    let saved = SentenceAssociationPreference.saveGrammarModel(model)
    record(saved, group: .intelligence)
    if saved && model == .wanxiang && !resourcePacks.available(wanxiangPackID) {
      resourcePacks.request(wanxiangPackID)
    }
  }

  private func record(_ saved: Bool, group: PageGroup) {
    failedGroup = saved ? nil : group
    if !saved { reload() }
  }

  private func reload() {
    resourcePacks.reload()
    guard let preferences = MetasequoiaInputSessionBridge.loadSharedPreferences() else { return }
    chinesePunctuation = preferences["chinese_punctuation"] as? Bool ?? true
    paired = preferences["paired_punctuation"] as? Bool ?? true
    smart = preferences["smart_punctuation"] as? Bool ?? true
    lock = preferences["punctuation_lock"] as? String ?? "follow"
    sentenceLevel = SentenceAssociationPreference.level(in: preferences)
    grammarModel = SentenceAssociationPreference.grammarModel(in: preferences)
    nextWordPrediction = preferences[NextWordPredictionButtons.enabledKey] as? Bool ?? false
    predictionButtons = NextWordPredictionButtons.style(in: preferences)
  }
}
