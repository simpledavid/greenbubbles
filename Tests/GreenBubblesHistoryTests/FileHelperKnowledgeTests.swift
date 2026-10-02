import CryptoKit
import Foundation
import SQLite3
import Testing

@testable import GreenBubblesHistory

@Suite("File Helper local knowledge")
struct FileHelperKnowledgeTests {
  @Test(
    "imports synthetic databases through the actual pinned CLI",
    .enabled(if: ProcessInfo.processInfo.environment["GREENBUBBLES_TEST_CLI"] != nil))
  func integratesWithReleaseCLI() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["GREENBUBBLES_TEST_CLI"])
    let root = knowledgeTestRoot().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "db_storage")
    try FileHelperKnowledgeStore.privateDirectory(root)
    for folder in ["contact", "session", "message"] {
      try FileHelperKnowledgeStore.privateDirectory(source.appending(path: folder))
    }
    func database(_ path: String, sql: String) throws {
      let url = source.appending(path: path)
      let db = try SQLiteConnection(
        path: url.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
      try db.execute(sql)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    try database(
      "contact/contact.db",
      sql: """
        CREATE TABLE contact(username TEXT PRIMARY KEY, alias BLOB, remark BLOB, nick_name BLOB);
        INSERT INTO contact VALUES ('filehelper','','','文件传输助手'), ('self','','','合成账号');
        """)
    try database(
      "session/session.db",
      sql: """
        CREATE TABLE SessionTable(username TEXT NOT NULL, sort_timestamp INTEGER NOT NULL,
          summary BLOB, last_msg_type INTEGER, last_msg_sender TEXT, last_sender_display_name TEXT);
        INSERT INTO SessionTable VALUES ('filehelper',1700000000,'合成示例',1,'self','合成账号');
        """)
    let table =
      "Msg_"
      + Insecure.MD5.hash(data: Data("filehelper".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let body = "官方 CLI 联通测试\n原文和链接：https://example.com/knowledge"
    let hex = Data(body.utf8).map { String(format: "%02x", $0) }.joined()
    try database(
      "message/message_0.db",
      sql: """
        CREATE TABLE Name2Id(user_name TEXT);
        INSERT INTO Name2Id(rowid,user_name) VALUES (1,'self');
        CREATE TABLE [\(table)](server_id INTEGER, sort_seq INTEGER, local_type INTEGER,
          real_sender_id INTEGER, create_time INTEGER, status INTEGER, message_content BLOB,
          packed_info_data BLOB, WCDB_CT_message_content INTEGER, compress_content BLOB);
        INSERT INTO [\(table)](server_id,sort_seq,local_type,real_sender_id,create_time,status,
          message_content,WCDB_CT_message_content) VALUES (1,1,1,1,1700000000,0,X'\(hex)',0);
        """)
    let store = try FileHelperKnowledgeStore(root: root.appending(path: "knowledge"))
    let live = WeChatFileHelperSource(
      configuration: HistoryDirectConfiguration(
        executableURL: URL(fileURLWithPath: executable), sourceURL: source, accessMode: .decrypted),
      keyFile: root.appending(path: "unused-key"))
    let result = try await FileHelperKnowledgeSync(store: store).sync(source: live)
    #expect(result.inserted == 1)
    #expect(result.historyComplete)
    #expect(!result.incompleteSource)
    let saved = try #require(try await store.list().first)
    #expect(saved.body == body)
    #expect(saved.links == ["https://example.com/knowledge"])
    #expect(saved.original.conversationID == "filehelper")
  }

  @Test("keeps exact Chinese text and links, excludes other chats and service messages")
  func projectsUserContent() throws {
    let body = "记录 100% 的想法\n\nhttps://example.com/a?q=学习"
    let message = try knowledgeMessage("one", content: ["Text": body])
    let item = try #require(KnowledgeItem.project(message, sourceIdentity: "account-a"))
    #expect(item.body == body)
    #expect(item.kind == .link)
    #expect(item.links.count == 1)
    #expect(item.original == message)
    #expect(
      KnowledgeItem.project(
        try knowledgeMessage("other", conversation: "friend"),
        sourceIdentity: "account-a") == nil)
    #expect(
      KnowledgeItem.project(
        try knowledgeMessage("service", sender: "filehelper"),
        sourceIdentity: "account-a") == nil)
    #expect(
      KnowledgeItem.project(
        try knowledgeMessage("recall", type: 10002),
        sourceIdentity: "account-a") == nil)
  }

  @Test("survives restart, deduplicates by account, and searches literal Chinese punctuation")
  func persistsAndSearches() async throws {
    let root = knowledgeTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileHelperKnowledgeStore(root: root)
    let raw = try knowledgeMessage("same-id", content: ["Text": "保留 100%_ 原文"])
    let a = try #require(KnowledgeItem.project(raw, sourceIdentity: "a"))
    let b = try #require(KnowledgeItem.project(raw, sourceIdentity: "b"))
    try await store.save(a)
    try await store.save(a)
    try await store.save(b)
    let reopened = try FileHelperKnowledgeStore(root: root)
    #expect(try await reopened.summary().total == 2)
    #expect(try await reopened.list(query: "100%_").count == 2)
    #expect(try await reopened.list(query: "100%x").isEmpty)
    #expect(try await reopened.item(a.id)?.body == "保留 100%_ 原文")
    let originalURL = root.appending(path: "entries/\(a.id)/source.json")
    let original = try JSONDecoder().decode(
      HistoryDirectMessage.self,
      from: Data(contentsOf: originalURL))
    #expect(original == raw)
    try FileHelperKnowledgeStore.validatePrivateFile(originalURL)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
  }

  @Test("preserves newer gaps while resuming a bounded historical import")
  func resumesWithoutGaps() async throws {
    let root = knowledgeTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileHelperKnowledgeStore(root: root)
    let first = KnowledgeTestSource(pages: [
      "head": try knowledgePage([10, 9], next: "old"),
      "old": try knowledgePage([8, 7]),
    ])
    let initial = try await FileHelperKnowledgeSync(store: store).sync(
      source: first, maximumPages: 1)
    #expect(!initial.historyComplete)
    let newer = KnowledgeTestSource(pages: [
      "head": try knowledgePage([14, 13], next: "recent"),
      "recent": try knowledgePage([12, 11], next: "overlap"),
      "overlap": try knowledgePage([10, 9], next: "old"),
      "old": try knowledgePage([8, 7]),
    ])
    let bounded = try await FileHelperKnowledgeSync(store: store).sync(
      source: newer, maximumPages: 2)
    #expect(bounded.inserted == 4)
    #expect(!bounded.historyComplete)
    #expect(try await store.syncState(source: "account-a").pendingCursors == ["overlap", "old"])
    // Recreate both store and synchronizer to exercise the durable checkpoints.
    let resumed = try FileHelperKnowledgeStore(root: root)
    let completed = try await FileHelperKnowledgeSync(store: resumed).sync(source: newer)
    #expect(completed.historyComplete)
    #expect(completed.inserted == 2)
    #expect(try await resumed.summary().total == 8)
    #expect(await newer.cursors == ["head", "recent", "head", "overlap", "old"])
    let repeated = try await FileHelperKnowledgeSync(store: resumed).sync(source: newer)
    #expect(repeated.inserted == 0)
  }

  @Test("does not advance over an unreadable shard")
  func revisitsIncompletePages() async throws {
    let root = knowledgeTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileHelperKnowledgeStore(root: root)
    let partial = KnowledgeTestSource(pages: [
      "head": try knowledgePage([4], next: "older", complete: false)
    ])
    let result = try await FileHelperKnowledgeSync(store: store).sync(source: partial)
    #expect(result.incompleteSource)
    #expect(!result.historyComplete)
    #expect(try await store.syncState(source: "account-a").backfillCursor == nil)
    #expect(await partial.cursors == ["head"])
    let fixed = KnowledgeTestSource(pages: [
      "head": try knowledgePage([4, 3], next: "older"), "older": try knowledgePage([2, 1]),
    ])
    #expect(try await FileHelperKnowledgeSync(store: store).sync(source: fixed).historyComplete)
    #expect(try await store.summary().total == 4)
  }

  @Test("copies verified attachments independently and retries only the configured account")
  func capturesAttachments() async throws {
    let root = knowledgeTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileHelperKnowledgeStore(root: root)
    let raw = try knowledgeMessage("file", content: ["File": ["title": "../说明.txt"]], type: 49)
    let pageA = knowledgePage(messages: [raw], identity: "account-a")
    let missing = KnowledgeTestSource(pages: ["head": pageA], availability: "notDownloaded")
    _ = try await FileHelperKnowledgeSync(store: store).sync(source: missing)
    let itemA = try #require(KnowledgeItem.project(raw, sourceIdentity: "account-a"))
    #expect(try await store.item(itemA.id)?.attachment?.state == .unavailable)
    let corrupt = KnowledgeTestSource(
      pages: ["head": knowledgePage(messages: [raw], identity: "account-b")], corrupt: true)
    _ = try await FileHelperKnowledgeSync(store: store).sync(source: corrupt)
    let itemB = try #require(KnowledgeItem.project(raw, sourceIdentity: "account-b"))
    #expect(try await store.item(itemB.id)?.attachment?.state == .failed)
    let repaired = KnowledgeTestSource(pages: [
      "head": knowledgePage(messages: [raw], identity: "account-b")
    ])
    #expect(try await FileHelperKnowledgeSync(store: store).retryAttachments(source: repaired) == 1)
    #expect(await repaired.inspectedAccounts == ["account-b"])
    #expect(try await store.item(itemA.id)?.attachment?.state == .unavailable)
    let saved = try #require(try await store.item(itemB.id))
    let copy = try #require(store.attachmentURL(for: saved))
    #expect(copy.path.hasPrefix(root.path + "/entries/"))
    #expect(try Data(contentsOf: copy) == KnowledgeTestSource.bytes)
    #expect(saved.attachment?.sha256 == KnowledgeTestSource.digest)
    // Reading the saved copy does not require a source, key, or running WeChat.
    try FileHelperKnowledgeStore.validatePrivateFile(copy)
  }

  @Test("rejects metadata symlinks before writing outside the library")
  func rejectsSymlinks() async throws {
    let root = knowledgeTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileHelperKnowledgeStore(root: root)
    let item = try #require(
      KnowledgeItem.project(try knowledgeMessage("unsafe"), sourceIdentity: "a"))
    let folder = root.appending(path: "entries/\(item.id)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let untouched = root.appending(path: "untouched")
    try FileHelperKnowledgeStore.writePrivate(Data("original".utf8), to: untouched)
    try FileManager.default.createSymbolicLink(
      at: folder.appending(path: "source.json"), withDestinationURL: untouched)
    await #expect(throws: KnowledgeError.self) { try await store.save(item) }
    #expect(try String(contentsOf: untouched, encoding: .utf8) == "original")
  }
}

private func knowledgeTestRoot() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "knowledge-tests-\(UUID().uuidString)")
}

private func knowledgeMessage(
  _ id: String, content: [String: Any] = ["Text": "测试原文"],
  conversation: String = "filehelper", sender: String = "self", type: Int = 1
) throws -> HistoryDirectMessage {
  let data = try JSONSerialization.data(withJSONObject: [
    "id": id, "conversationId": conversation, "sortSequence": 1, "serverId": 1,
    "messageType": type, "messageTypeLabel": "Text", "messageSubtype": 0,
    "messageSubtypeLabel": "None", "sender": sender, "createdAtUnix": 1_700_000_000,
    "status": 0, "content": content, "contentDecodeState": "decoded", "contentTruncated": false,
  ])
  return try JSONDecoder().decode(HistoryDirectMessage.self, from: data)
}

private func knowledgePage(_ ids: [Int], next: String? = nil, complete: Bool = true) throws
  -> HistoryDirectMessagePage
{
  knowledgePage(
    messages: try ids.map { try knowledgeMessage(String($0)) }, next: next, complete: complete)
}

private func knowledgePage(
  messages: [HistoryDirectMessage], identity: String = "account-a",
  next: String? = nil, complete: Bool = true
) -> HistoryDirectMessagePage {
  HistoryDirectMessagePage(
    schema: "greenbubbles.query.v1", formatVersion: 1,
    operation: "messages.list", ok: true,
    source: HistoryDirectSource(mode: "liveEncrypted", identity: identity),
    consistency: HistoryDirectConsistency(
      guarantee: "bounded", databaseCount: 1,
      crossDatabaseAtomic: false, coverageComplete: complete, observedAtUnixMilliseconds: 1),
    page: HistoryDirectPage(
      limit: 100, returned: messages.count, hasMore: next != nil, nextCursor: next),
    warnings: [], items: messages)
}

private actor KnowledgeTestSource: FileHelperKnowledgeSource {
  static let bytes = Data("独立保存的原始附件".utf8)
  static let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  let pages: [String: HistoryDirectMessagePage]
  let availability: String
  let corrupt: Bool
  var cursors: [String] = []
  var inspectedAccounts: [String] = []

  init(
    pages: [String: HistoryDirectMessagePage], availability: String = "downloaded",
    corrupt: Bool = false
  ) {
    self.pages = pages
    self.availability = availability
    self.corrupt = corrupt
  }

  func page(cursor: String?) async throws -> HistoryDirectMessagePage {
    cursors.append(cursor ?? "head")
    guard let page = pages[cursor ?? "head"] else { throw KnowledgeError.incompleteSource }
    return page
  }

  func inspect(_ item: KnowledgeItem) async throws -> KnowledgeAttachmentInspection {
    inspectedAccounts.append(item.sourceIdentity)
    return KnowledgeAttachmentInspection(
      kind: "document", availability: availability,
      preferredAttachmentId: "fixture", preferredSourceFormat: "txt")
  }

  func materialize(_ item: KnowledgeItem, attachmentID: String, output: URL) async throws
    -> KnowledgeAttachmentMaterialization
  {
    try FileHelperKnowledgeStore.writePrivate(Self.bytes, to: output)
    return KnowledgeAttachmentMaterialization(
      decodedFormat: "txt", decodedByteCount: UInt64(Self.bytes.count),
      decodedSha256: corrupt ? "incorrect" : Self.digest)
  }
}
