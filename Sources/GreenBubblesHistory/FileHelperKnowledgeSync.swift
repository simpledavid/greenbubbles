import CryptoKit
import Foundation

public struct KnowledgeAttachmentInspection: Decodable, Sendable {
  public let kind: String
  public let availability: String
  public let preferredAttachmentId: String?
  public let preferredSourceFormat: String?
}

public struct KnowledgeAttachmentMaterialization: Decodable, Sendable {
  public let decodedFormat: String
  public let decodedByteCount: UInt64
  public let decodedSha256: String
}

public protocol FileHelperKnowledgeSource: Sendable {
  func page(cursor: String?) async throws -> HistoryDirectMessagePage
  func inspect(_ item: KnowledgeItem) async throws -> KnowledgeAttachmentInspection
  func materialize(_ item: KnowledgeItem, attachmentID: String, output: URL)
    async throws -> KnowledgeAttachmentMaterialization
}

public struct WeChatFileHelperSource: FileHelperKnowledgeSource {
  public let configuration: HistoryDirectConfiguration
  public let keyFile: URL
  private let client = HistoryDirectQueryClient()

  public init(configuration: HistoryDirectConfiguration, keyFile: URL) {
    self.configuration = configuration
    self.keyFile = keyFile
  }

  public func page(cursor: String?) async throws -> HistoryDirectMessagePage {
    var key = try readKey()
    defer { key.resetBytes(in: 0..<key.count) }
    return try await client.messages(
      configuration: configuration, keyUTF8: key,
      conversationID: "filehelper", limit: 100, cursor: cursor)
  }

  public func inspect(_ item: KnowledgeItem) async throws -> KnowledgeAttachmentInspection {
    guard let kind = item.kind.attachmentKind else { throw KnowledgeError.invalidAttachment }
    var key = try readKey()
    defer { key.resetBytes(in: 0..<key.count) }
    return try await client.inspectKnowledgeAttachment(
      configuration: configuration, keyUTF8: key,
      messageID: item.messageID, kind: kind)
  }

  public func materialize(_ item: KnowledgeItem, attachmentID: String, output: URL)
    async throws -> KnowledgeAttachmentMaterialization
  {
    guard let kind = item.kind.attachmentKind else { throw KnowledgeError.invalidAttachment }
    var key = try readKey()
    defer { key.resetBytes(in: 0..<key.count) }
    return try await client.materializeKnowledgeAttachment(
      configuration: configuration,
      keyUTF8: key, messageID: item.messageID, kind: kind, attachmentID: attachmentID,
      output: output)
  }

  private func readKey() throws -> [UInt8] {
    if configuration.accessMode == .decrypted { return [] }
    guard FileManager.default.fileExists(atPath: keyFile.path) else {
      throw KnowledgeError.missingKey
    }
    try FileHelperKnowledgeStore.validatePrivateFile(keyFile)
    let size = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.size] as? NSNumber
    guard (size?.intValue ?? 1000) <= 128 else { throw KnowledgeError.missingKey }
    var data = try Data(contentsOf: keyFile)
    defer { data.resetBytes(in: 0..<data.count) }
    while data.last == 10 || data.last == 13 { data.removeLast() }
    guard data.count == 64,
      data.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { throw KnowledgeError.missingKey }
    return Array(data)
  }
}

public struct KnowledgeSyncResult: Sendable {
  public let inserted: Int
  public let visited: Int
  public let historyComplete: Bool
  public let incompleteSource: Bool
}

public actor FileHelperKnowledgeSync {
  private let store: FileHelperKnowledgeStore
  private var isRunning = false

  public init(store: FileHelperKnowledgeStore) { self.store = store }

  public func sync(
    source: any FileHelperKnowledgeSource, maximumPages: Int = 20,
    progress: @escaping @Sendable (Int) -> Void = { _ in }
  ) async throws -> KnowledgeSyncResult {
    guard !isRunning else { throw KnowledgeError.syncBusy }
    isRunning = true
    defer { isRunning = false }
    var page = try await source.page(cursor: nil)
    let identity = page.source.identity
    var state = try await store.syncState(source: identity)
    var backlog = state.pendingCursors ?? state.backfillCursor.map { [$0] } ?? []
    var activeCursor: String?
    var cursors = Set<String>()
    var inserted = 0
    var visited = 0
    var incomplete = false
    let maximum = min(max(maximumPages, 1), 100)
    for pageNumber in 0..<maximum {
      try Task.checkCancellation()
      guard page.source.identity == identity else { throw KnowledgeError.incompleteSource }
      var allKnown = true
      for message in page.items {
        guard let projected = KnowledgeItem.project(message, sourceIdentity: identity) else {
          continue
        }
        let exists = try await store.contains(projected.id)
        allKnown = allKnown && exists
        if !exists { inserted += 1 }
        var item = try await store.save(projected)
        if item.attachment != nil && (!exists || item.attachment?.state == .pending) {
          item = try await captureAttachment(item, source: source)
          try await store.update(item)
        }
        visited += 1
        progress(visited)
      }
      // Persist readable messages, but never advance a cursor over unreadable
      // shards. A later successful run must revisit this page.
      if !page.consistency.coverageComplete {
        incomplete = true
        break
      }
      if let activeCursor { backlog.removeAll { $0 == activeCursor } }
      if !page.page.hasMore {
        state.backfillComplete = true
      } else if !allKnown || (!state.backfillComplete && backlog.isEmpty) {
        guard let next = page.page.nextCursor, !cursors.contains(next) else {
          throw KnowledgeError.incompleteSource
        }
        // Keep the older checkpoint when filling a new gap at the head. If the
        // page budget is exhausted, both ranges remain resumable after restart.
        if !backlog.contains(next) { backlog.insert(next, at: 0) }
      }
      backlog.removeAll { cursors.contains($0) }
      state.pendingCursors = backlog
      state.backfillCursor = backlog.first
      try await store.setSyncState(state, source: identity)
      guard let next = backlog.first else { break }
      if pageNumber + 1 < maximum {
        cursors.insert(next)
        activeCursor = next
        page = try await source.page(cursor: next)
      }
    }
    state.lastSync = Date()
    try await store.setSyncState(state, source: identity)
    return KnowledgeSyncResult(
      inserted: inserted, visited: visited,
      historyComplete: state.backfillComplete && backlog.isEmpty, incompleteSource: incomplete)
  }

  public func retryAttachments(source: any FileHelperKnowledgeSource) async throws -> Int {
    guard !isRunning else { throw KnowledgeError.syncBusy }
    isRunning = true
    defer { isRunning = false }
    let identity = try await source.page(cursor: nil).source.identity
    var saved = 0
    // Retry one bounded batch, including old messages whose file was downloaded
    // after their message had already been imported.
    for item in try await store.pendingAttachments(source: identity) {
      try Task.checkCancellation()
      let updated = try await captureAttachment(item, source: source)
      try await store.update(updated)
      if updated.attachment?.state == .saved { saved += 1 }
    }
    return saved
  }

  private func captureAttachment(_ input: KnowledgeItem, source: any FileHelperKnowledgeSource)
    async throws -> KnowledgeItem
  {
    var item = input
    item.attachment?.lastAttempt = Date()
    do {
      let inspected = try await source.inspect(item)
      guard inspected.availability == "downloaded", let id = inspected.preferredAttachmentId else {
        item.attachment?.state = .unavailable
        item.attachment?.detail = "附件未下载、已过期，或当前 Mac 上找不到。可下载后重试。"
        return item
      }
      let output = try await store.attachmentDestination(
        for: item,
        format: inspected.preferredSourceFormat ?? "")
      // Recover a copy that was published before a previous run was interrupted.
      // Compare a newly materialized copy rather than trusting the old path.
      let temporary = output.deletingLastPathComponent().appending(
        path: "capture-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: temporary) }
      let result = try await source.materialize(item, attachmentID: id, output: temporary)
      try FileHelperKnowledgeStore.validatePrivateFile(temporary)
      let digest = try Self.digestFile(temporary)
      let size =
        try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
      guard digest == result.decodedSha256, size?.uint64Value == result.decodedByteCount else {
        throw KnowledgeError.invalidAttachment
      }
      let final = try await store.attachmentDestination(for: item, format: result.decodedFormat)
      if FileManager.default.fileExists(atPath: final.path) {
        try FileHelperKnowledgeStore.validatePrivateFile(final)
        guard try Self.digestFile(final) == digest else { throw KnowledgeError.invalidAttachment }
      } else {
        try FileManager.default.moveItem(at: temporary, to: final)
      }
      item.attachment?.state = .saved
      item.attachment?.relativePath = try await store.relativeAttachmentPath(final)
      item.attachment?.sha256 = digest
      item.attachment?.detail = nil
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      item.attachment?.state = .failed
      item.attachment?.detail = "附件保存失败，原消息已保留。请下载附件后重试。"
    }
    return item
  }

  private static func digestFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
