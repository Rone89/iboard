import Combine
import Foundation
import Network

/// 下载状态只由主应用维护，键盘扩展不负责联网安装。
@MainActor
final class IOSResourcePackStore: ObservableObject {
  static let shared = IOSResourcePackStore()
  struct Status {
    var phase: String
    var percent: Int = 0
    var detail: String? = nil
    var message: String {
      switch phase {
      case "download": return "下载中 \(percent)%"
      case "import", "verify": return "校验安装中"
      case "done": return "安装完成"
      case "cancelled": return "已取消，可继续下载"
      case "failed":
        if let detail, !detail.isEmpty { return "下载失败（\(detail)），点按重试" }
        return "下载失败，点按重试"
      default: return "准备下载"
      }
    }
    var running: Bool { !["failed", "cancelled"].contains(phase) }
  }

  @Published private(set) var packs: [String: IOSResourcePacks.Pack] = [:]
  @Published private(set) var statuses: [String: Status] = [:]
  @Published var meteredRequest: String?
  @Published private(set) var loadFailed = false
  private var downloads: [String: IOSResourcePackDownload] = [:]
  private var expensiveNetwork = false
  private let monitor = NWPathMonitor()

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in self?.expensiveNetwork = path.isExpensive || path.isConstrained }
    }
    monitor.start(queue: DispatchQueue(label: "app.msime.ios.resource-network"))
  }

  func reload() {
    Task { [self] in
      let result = await Task.detached { Result { try IOSResourcePacks.list() } }.value
      switch result {
      case .success(let listed):
        packs = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
        InputSchemePreference.refreshResourceAvailability()
        loadFailed = false
      case .failure: loadFailed = true
      }
    }
  }

  func available(_ id: String) -> Bool { IOSResourcePacks.bundled(id) || packs[id]?.installed == true }
  func size(_ id: String) -> String {
    guard let size = packs[id]?.size else { return "获取大小中" }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }
  func describe(_ id: String) -> String {
    if let status = statuses[id] { return status.message }
    if IOSResourcePacks.bundled(id) { return "已内置" }
    if available(id) { return "已下载" }
    return "需下载 \(size(id))"
  }

  func request(_ id: String) {
    guard !available(id), statuses[id]?.running != true else { return }
    if expensiveNetwork { meteredRequest = id }
    else { start(id) }
  }

  func start(_ id: String) {
    meteredRequest = nil
    guard !available(id), statuses[id]?.running != true else { return }
    let download = IOSResourcePackDownload(id: id)
    downloads[id] = download
    statuses[id] = Status(phase: "download")
    Task { [self] in
      let result = await Task.detached { [weak self] in
        Result { [weak self] in
          try download.install { [weak self] phase, done, total in
            let percentage = total == 0 ? 0 : Int(min(100, Double(done) / Double(total) * 100))
            Task { @MainActor in
              guard let self, self.downloads[id] === download else { return }
              if self.statuses[id]?.percent != percentage || self.statuses[id]?.phase != phase {
                self.statuses[id] = Status(phase: phase, percent: percentage)
              }
            }
          }
        }
      }.value
      guard downloads[id] === download else { return }
      downloads[id] = nil
      switch result {
      case .success:
        statuses[id] = nil
        reload()
        let label = id.hasPrefix("grammar-model-") ? "语法模型" : "词库"
        ToastCenter.shared.show("\(label)已下载，重新打开键盘即可使用")
      case .failure(let error):
        let code = (error as? IOSResourcePacks.Failure)?.code ?? error.localizedDescription
        let cancelled = code == "local_model_cancelled"
        statuses[id] = Status(phase: cancelled ? "cancelled" : "failed", detail: cancelled ? nil : Self.failureSummary(code))
      }
    }
  }

  private static func failureSummary(_ code: String) -> String {
    if code.hasPrefix("url_error:") {
      let raw = Int(code.dropFirst("url_error:".count))
      switch raw {
      case URLError.timedOut.rawValue: return "网络超时"
      case URLError.notConnectedToInternet.rawValue: return "无网络连接"
      case URLError.cannotFindHost.rawValue, URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue:
        return "无法连接 GitHub，请检查网络或代理"
      case URLError.secureConnectionFailed.rawValue: return "TLS 连接失败"
      default: return "网络错误 \(raw ?? 0)"
      }
    }
    if code.hasPrefix("local_model_http_status") {
      return code.replacingOccurrences(of: "local_model_http_status:", with: "HTTP ")
    }
    if code.contains("checksum_mismatch") || code.contains("format_mismatch") || code.contains("size_mismatch") {
      return "文件校验失败"
    }
    if code.contains("network") {
      return "网络连接异常"
    }
    if code.contains("io") {
      return "本地存储空间或写入失败"
    }
    return code
  }

  func cancel(_ id: String) { downloads[id]?.cancel() }

  func remove(_ id: String) {
    guard statuses[id]?.running != true else { return }
    Task { [self] in
      let removed = await Task.detached { (try? IOSResourcePacks.remove(id)) ?? false }.value
      reload()
      if removed {
        let label = id.hasPrefix("grammar-model-") ? "语法模型" : "资源"
        ToastCenter.shared.show("已删除\(label)")
      }
    }
  }
}
