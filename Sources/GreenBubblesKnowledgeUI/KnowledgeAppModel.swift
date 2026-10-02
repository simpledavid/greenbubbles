import AppKit
import Foundation
import GreenBubblesCore
import GreenBubblesHistory
import Observation

enum KnowledgeSheet: String, Identifiable {
  case connection
  var id: String { rawValue }
}

@MainActor
@Observable
final class KnowledgeAppModel {
  var items: [KnowledgeItem] = []
  var selectedID: String?
  var query = ""
  var filter: KnowledgeKind?
  var total = 0
  var attachmentCount = 0
  var isSyncing = false
  var status = "等待连接文件传输助手"
  var error: String?
  var sheet: KnowledgeSheet?
  var autoSync = false
  var historyComplete = false
  var hasMore = false
  var isDemo = false
  var executablePath = ""
  var sourcePath = ""
  var keyPath = ""
  var libraryPath = ""
  var lastSync: Date?
  private var store: FileHelperKnowledgeStore?
  private var synchronizer: FileHelperKnowledgeSync?
  private var syncTask: Task<Void, Never>?
  private var timerTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var didStart = false

  init(storageName: String = "GreenBubblesKnowledge") {
    let defaults = UserDefaults.standard
    executablePath = defaults.string(forKey: "knowledge.executable") ?? ""
    if executablePath.isEmpty {
      let candidates = [
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "greenbubbles").path,
        "/opt/homebrew/bin/greenbubbles", "/usr/local/bin/greenbubbles",
      ].compactMap { $0 }
      executablePath =
        candidates.first {
          FileManager.default.isExecutableFile(atPath: $0)
        } ?? ""
    }
    sourcePath = defaults.string(forKey: "knowledge.source") ?? ""
    keyPath =
      defaults.string(forKey: "knowledge.keyFile")
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".greenbubbles-acquire/passphrase.txt").path
    libraryPath =
      defaults.string(forKey: "knowledge.library")
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: storageName, directoryHint: .isDirectory).path
    let arguments = Array(CommandLine.arguments.dropFirst())
    if let index = arguments.firstIndex(of: "--library"), arguments.indices.contains(index + 1) {
      libraryPath = arguments[index + 1]
    }
    isDemo = arguments.contains("--demo")
    autoSync = !isDemo && defaults.bool(forKey: "knowledge.autoSync")
  }

  var selectedItem: KnowledgeItem? { items.first { $0.id == selectedID } }

  func start() async {
    guard !didStart else { return }
    didStart = true
    await openLibrary()
    if isDemo {
      await seedDemo()
      status = "示例模式 · 内容为合成演示数据"
    }
    await reload()
    if autoSync && !sourcePath.isEmpty { setAutoSync() }
  }

  func openLibrary() async {
    do {
      let opened = try FileHelperKnowledgeStore(root: URL(fileURLWithPath: libraryPath))
      store = opened
      synchronizer = FileHelperKnowledgeSync(store: opened)
    } catch { self.error = String(describing: error) }
  }

  func reload(loadMore: Bool = false) async {
    guard let store else { return }
    loadGeneration += 1
    let generation = loadGeneration
    let requestedQuery = query
    let requestedFilter = filter
    let offset = loadMore ? items.count : 0
    do {
      let values = try await store.list(
        query: requestedQuery, kind: requestedFilter,
        limit: 200, offset: offset)
      let summary = try await store.summary()
      guard generation == loadGeneration else { return }
      items = loadMore ? items + values : values
      total = summary.total
      attachmentCount = summary.attachments
      hasMore = values.count == 200
      if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
        selectedID = items.first?.id
      }
    } catch { self.error = String(describing: error) }
  }

  func discoverSource() -> String? {
    let roots = WeChatAccountDiscovery().databaseRoots()
    if roots.count == 1 {
      return roots[0].path
    } else if roots.isEmpty {
      error = "未找到微信数据目录。请先在 Mac 登录微信，或手动选择 db_storage 文件夹。"
    } else {
      error = "找到多个微信账号，请手动选择要同步的账号目录。"
    }
    return nil
  }

  func saveConnection(executable: String, source: String, key: String, library: String) async
    -> Bool
  {
    guard !isSyncing else { return false }
    guard FileManager.default.isExecutableFile(atPath: executable), !source.isEmpty,
      FileManager.default.fileExists(atPath: source)
    else {
      error = "请选择读取工具和微信数据目录。"
      return false
    }
    guard FileManager.default.fileExists(atPath: key) else {
      error = "还没有微信数据库密钥，请按首次配置说明完成配置。"
      return false
    }
    do {
      try FileHelperKnowledgeStore.validatePrivateFile(URL(fileURLWithPath: key))
      let opened = try FileHelperKnowledgeStore(root: URL(fileURLWithPath: library))
      store = opened
      synchronizer = FileHelperKnowledgeSync(store: opened)
    } catch {
      self.error = String(describing: error)
      return false
    }
    executablePath = executable
    sourcePath = source
    keyPath = key
    libraryPath = library
    let defaults = UserDefaults.standard
    defaults.set(executablePath, forKey: "knowledge.executable")
    defaults.set(sourcePath, forKey: "knowledge.source")
    defaults.set(keyPath, forKey: "knowledge.keyFile")
    defaults.set(libraryPath, forKey: "knowledge.library")
    isDemo = false
    error = nil
    await reload()
    return true
  }

  func sync(retryAttachments: Bool = false) {
    guard !isSyncing, !isDemo else { return }
    guard let synchronizer, !executablePath.isEmpty, !sourcePath.isEmpty else {
      sheet = .connection
      return
    }
    let source = WeChatFileHelperSource(
      configuration: HistoryDirectConfiguration(
        executableURL: URL(fileURLWithPath: executablePath),
        sourceURL: URL(fileURLWithPath: sourcePath), accessMode: .liveEncrypted),
      keyFile: URL(fileURLWithPath: keyPath))
    isSyncing = true
    error = nil
    status = "正在读取文件传输助手…"
    syncTask = Task {
      defer { isSyncing = false }
      do {
        if retryAttachments {
          status = "正在重试未保存的附件…"
          let saved = try await synchronizer.retryAttachments(source: source)
          status = "本批次保存 \(saved) 个附件 · 未下载的可下载后继续重试"
        } else {
          let result = try await synchronizer.sync(source: source) { [weak self] count in
            Task { @MainActor in self?.status = "正在保存 · 已处理 \(count) 条" }
          }
          historyComplete = result.historyComplete
          lastSync = Date()
          if result.incompleteSource {
            error = KnowledgeError.incompleteSource.description
          }
          status =
            result.historyComplete
            ? "同步完成 · 新增 \(result.inserted) 条"
            : "新增 \(result.inserted) 条 · 历史记录未读完，继续同步即可"
        }
      } catch is CancellationError {
        status = "同步已停止 · 已保存内容保留"
      } catch {
        self.error = String(describing: error)
        status = "同步未完成"
      }
      await reload()
    }
  }

  func stopSync() { syncTask?.cancel() }

  func setAutoSync() {
    timerTask?.cancel()
    if !isDemo { UserDefaults.standard.set(autoSync, forKey: "knowledge.autoSync") }
    guard autoSync, !isDemo else { return }
    sync()
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self else { return }
        self.sync()
      }
    }
  }

  func openAttachment(_ item: KnowledgeItem) {
    guard let url = store?.attachmentURL(for: item) else { return }
    guard FileManager.default.fileExists(atPath: url.path) else {
      error = "已保存的附件被移动或删除了，请检查知识库文件夹。"
      return
    }
    NSWorkspace.shared.open(url)
  }

  func revealLibrary() { NSWorkspace.shared.open(URL(fileURLWithPath: libraryPath)) }

  func revealEntry(_ item: KnowledgeItem) {
    NSWorkspace.shared.activateFileViewerSelecting([
      URL(fileURLWithPath: libraryPath).appending(path: "entries/\(item.id)/note.md")
    ])
  }

  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func seedDemo() async {
    guard let store else { return }
    let samples: [(String, String, UInt32)] = [
      (
        "demo-note",
        #"{"Text":"关于知识库的一个想法\n\n把零散的内容先收集起来，再慢慢建立自己的理解。\n\n以后看到值得保留的内容，直接发到文件传输助手。"}"#, 1
      ),
      (
        "demo-link",
        #"{"Link":{"title":"SwiftUI：用原生组件搭建 Mac 界面","description":"官方开发文档，留着以后查阅。","url":"https://developer.apple.com/documentation/swiftui"}}"#,
        49
      ),
      ("demo-file", #"{"File":{"title":"知识库使用说明.txt"}}"#, 49),
    ]
    for (offset, sample) in samples.enumerated() {
      let raw = """
        {"id":"\(sample.0)","conversationId":"filehelper","sortSequence":\(offset),
        "serverId":\(offset),"messageType":\(sample.2),"messageTypeLabel":"Text",
        "messageSubtype":0,"messageSubtypeLabel":"None","sender":"demo-owner",
        "createdAtUnix":1790902800,"status":0,"content":\(sample.1),
        "contentDecodeState":"decoded","contentTruncated":false}
        """
      do {
        let message = try JSONDecoder().decode(HistoryDirectMessage.self, from: Data(raw.utf8))
        guard var item = KnowledgeItem.project(message, sourceIdentity: "synthetic-demo") else {
          continue
        }
        if item.kind == .file {
          let destination = try await store.attachmentDestination(for: item, format: "txt")
          try Data("这是合成示例附件。你的真实附件会独立复制到知识库。\n".utf8).write(to: destination)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
          item.attachment?.state = .saved
          item.attachment?.relativePath = try await store.relativeAttachmentPath(destination)
        }
        try await store.save(item)
      } catch { self.error = String(describing: error) }
    }
  }
}
