import Foundation

/// 一次下载独立保存取消意图，覆盖工作线程启动和共享任务登记之前的窗口。
final class IOSResourcePackDownload: @unchecked Sendable {
  private static let wanxiangPackID = "grammar-model-wanxiang"
  private static let wanxiangDownloadURL = URL(
    string: "https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/wanxiang-lts-zh-hans.gram"
  )!
  private static let wanxiangFileName = "wanxiang-lts-zh-hans.gram"

  private let id: String
  private let lock = NSLock()
  private var cancelRequested = false
  private var registered = false
  private var finished = false
  private var activeURLTask: URLSessionDownloadTask?

  init(id: String) { self.id = id }

  func cancel() {
    lock.lock()
    cancelRequested = true
    let urlTask = activeURLTask
    let shouldCancelRust = registered && !finished
    lock.unlock()
    urlTask?.cancel()
    // 取消入口只设置共享标记，不触发回调；持锁让转发先于本次结束和下一次重试。
    if shouldCancelRust { IOSResourcePacks.cancel(id) }
  }

  func install(progress: @escaping (String, UInt64, UInt64) -> Void) throws {
    lock.lock()
    let cancelled = cancelRequested
    lock.unlock()
    defer {
      lock.lock()
      finished = true
      registered = false
      activeURLTask = nil
      lock.unlock()
    }
    if cancelled { throw IOSResourcePacks.Failure(code: "local_model_cancelled") }
    if id == Self.wanxiangPackID {
      try installWanxiangViaURLSession(progress: progress)
      return
    }
    try IOSResourcePacks.install(id) { [self] phase, done, total in
      // 共享层在登记后、任何 I/O 前同步发送首次进度，补发此前保存的取消。
      lock.lock()
      registered = true
      if cancelRequested { IOSResourcePacks.cancel(id) }
      lock.unlock()
      progress(phase, done, total)
    }
  }

  /// 万象 LTS（~373 MB）在 GitHub Release 原地更新且需走 iOS 系统网络/代理栈，改用原生 `URLSession`
  /// 流式下载到临时目录后，再交由共享层 `files` 导入接口执行 `.gram` 头部边界校验、计算摘要与原子发布。
  private func installWanxiangViaURLSession(progress: @escaping (String, UInt64, UInt64) -> Void) throws {
    let stagingDir = FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath()
      .appendingPathComponent("msime-wanxiang-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingDir) }
    let stagedFile = stagingDir.appendingPathComponent(Self.wanxiangFileName)

    progress("download", 0, 390_786_092)

    let delegate = WanxiangDownloadDelegate(destination: stagedFile, progress: progress)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 3600
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    var request = URLRequest(url: Self.wanxiangDownloadURL)
    request.setValue("iBoard-iOS", forHTTPHeaderField: "User-Agent")
    let task = session.downloadTask(with: request)

    lock.lock()
    let cancelledBeforeStart = cancelRequested
    if !cancelledBeforeStart { activeURLTask = task }
    lock.unlock()
    if cancelledBeforeStart {
      throw IOSResourcePacks.Failure(code: "local_model_cancelled")
    }

    task.resume()
    let downloadError = delegate.wait()

    lock.lock()
    activeURLTask = nil
    let cancelledAfterDownload = cancelRequested
    lock.unlock()

    if cancelledAfterDownload {
      throw IOSResourcePacks.Failure(code: "local_model_cancelled")
    }
    if let downloadError {
      throw downloadError
    }

    progress("verify", 1, 1)
    try IOSResourcePacks.install(id, files: [stagedFile]) { [self] phase, done, total in
      lock.lock()
      registered = true
      if cancelRequested { IOSResourcePacks.cancel(id) }
      lock.unlock()
      progress(phase == "import" ? "verify" : phase, done, total)
    }
  }
}

private final class WanxiangDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let progress: (String, UInt64, UInt64) -> Void
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var resultError: Error?
  private var finished = false

  init(destination: URL, progress: @escaping (String, UInt64, UInt64) -> Void) {
    self.destination = destination
    self.progress = progress
  }

  func wait() -> Error? {
    semaphore.wait()
    lock.lock()
    defer { lock.unlock() }
    return resultError
  }

  private func complete(with error: Error?) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    resultError = error
    lock.unlock()
    semaphore.signal()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let done = UInt64(max(0, totalBytesWritten))
    let total = totalBytesExpectedToWrite > 0 ? UInt64(totalBytesExpectedToWrite) : max(done, 390_786_092)
    progress("download", done, total)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
      complete(with: IOSResourcePacks.Failure(code: "local_model_http_status:\(http.statusCode)"))
      return
    }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: location, to: destination)
      complete(with: nil)
    } catch {
      complete(with: IOSResourcePacks.Failure(code: "local_model_io:\(error.localizedDescription)"))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let urlError = error as? URLError {
      if urlError.code == .cancelled {
        complete(with: IOSResourcePacks.Failure(code: "local_model_cancelled"))
      } else {
        complete(with: IOSResourcePacks.Failure(code: "url_error:\(urlError.code.rawValue)"))
      }
    } else if let error {
      complete(with: IOSResourcePacks.Failure(code: "local_model_network:\(error.localizedDescription)"))
    } else {
      complete(with: nil)
    }
  }
}
