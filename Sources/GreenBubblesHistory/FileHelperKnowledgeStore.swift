import CryptoKit
import Darwin
import Foundation
import SQLite3

public actor FileHelperKnowledgeStore {
  public nonisolated let root: URL
  private let database: SQLiteConnection
  private let encoder: JSONEncoder

  public init(root: URL) throws {
    self.root = root.standardizedFileURL
    try Self.privateDirectory(self.root)
    try Self.privateDirectory(self.root.appending(path: "entries"))
    let index = self.root.appending(path: "knowledge.sqlite")
    if FileManager.default.fileExists(atPath: index.path) {
      try Self.validatePrivateFile(index)
    }
    database = try SQLiteConnection(
      path: index.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try database.execute(
      """
      PRAGMA journal_mode = DELETE;
      PRAGMA synchronous = FULL;
      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY, source TEXT NOT NULL, sent REAL NOT NULL,
        kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
        payload TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS items_sent ON items(sent DESC, id);
      CREATE TABLE IF NOT EXISTS sync_state (source TEXT PRIMARY KEY, payload TEXT NOT NULL);
      """)
  }

  public func contains(_ id: String) throws -> Bool {
    let query = try database.prepare("SELECT 1 FROM items WHERE id = ?")
    try query.bind(id, at: 1)
    return try query.step() == SQLITE_ROW
  }

  public func item(_ id: String) throws -> KnowledgeItem? {
    let query = try database.prepare("SELECT payload FROM items WHERE id = ?")
    try query.bind(id, at: 1)
    guard try query.step() == SQLITE_ROW, let payload = query.text(at: 0) else { return nil }
    return try JSONDecoder().decode(KnowledgeItem.self, from: Data(payload.utf8))
  }

  @discardableResult
  public func save(_ incoming: KnowledgeItem) throws -> KnowledgeItem {
    var value = incoming
    if let previous = try item(value.id) {
      if previous.attachment != nil { value.attachment = previous.attachment }
    }
    try persist(value)
    return value
  }

  public func update(_ value: KnowledgeItem) throws { try persist(value) }

  public func list(
    query: String = "", kind: KnowledgeKind? = nil, limit: Int = 200,
    offset: Int = 0
  ) throws -> [KnowledgeItem] {
    let statement = try database.prepare(
      """
      SELECT payload FROM items WHERE (? IS NULL OR kind = ?)
        AND (title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')
      ORDER BY sent DESC, id LIMIT ? OFFSET ?
      """)
    let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    try statement.bind(kind?.rawValue, at: 1)
    try statement.bind(kind?.rawValue, at: 2)
    try statement.bind("%\(escaped)%", at: 3)
    try statement.bind("%\(escaped)%", at: 4)
    try statement.bind(min(max(limit, 1), 500), at: 5)
    try statement.bind(max(offset, 0), at: 6)
    var values: [KnowledgeItem] = []
    while try statement.step() == SQLITE_ROW {
      if let text = statement.text(at: 0) {
        values.append(try JSONDecoder().decode(KnowledgeItem.self, from: Data(text.utf8)))
      }
    }
    return values
  }

  public func summary() throws -> KnowledgeSummary {
    let query = try database.prepare(
      "SELECT COUNT(*), SUM(kind IN ('image','file','video','voice')) FROM items")
    _ = try query.step()
    return KnowledgeSummary(total: Int(query.int64(at: 0)), attachments: Int(query.int64(at: 1)))
  }

  public func pendingAttachments(source: String, limit: Int = 100) throws -> [KnowledgeItem] {
    let query = try database.prepare(
      """
      SELECT payload FROM items WHERE source = ?
        AND json_extract(payload, '$.attachment.state') IN ('pending','unavailable','failed')
      ORDER BY COALESCE(json_extract(payload, '$.attachment.lastAttempt'), 0), sent, id LIMIT ?
      """)
    try query.bind(source, at: 1)
    try query.bind(min(max(limit, 1), 100), at: 2)
    var items: [KnowledgeItem] = []
    while try query.step() == SQLITE_ROW {
      if let payload = query.text(at: 0) {
        items.append(try JSONDecoder().decode(KnowledgeItem.self, from: Data(payload.utf8)))
      }
    }
    return items
  }

  public func syncState(source: String) throws -> KnowledgeSyncState {
    let query = try database.prepare("SELECT payload FROM sync_state WHERE source = ?")
    try query.bind(source, at: 1)
    guard try query.step() == SQLITE_ROW, let text = query.text(at: 0) else {
      return KnowledgeSyncState()
    }
    return try JSONDecoder().decode(KnowledgeSyncState.self, from: Data(text.utf8))
  }

  public func setSyncState(_ state: KnowledgeSyncState, source: String) throws {
    let query = try database.prepare("INSERT OR REPLACE INTO sync_state VALUES (?, ?)")
    try query.bind(source, at: 1)
    try query.bind(String(decoding: encoder.encode(state), as: UTF8.self), at: 2)
    _ = try query.step()
  }

  public func attachmentDestination(for item: KnowledgeItem, format: String) throws -> URL {
    let directory = root.appending(path: "entries/\(item.id)")
    try Self.privateDirectory(directory)
    let safeFormat = format.lowercased().filter { $0.isASCII && $0.isLetter || $0.isNumber }
    let name = item.attachment?.name ?? "attachment"
    let sanitized = name.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\\", with: "_")
      .filter { !$0.isNewline && !$0.isWhitespace || $0 == " " }
    var leaf = String(sanitized.prefix(150))
    if leaf.isEmpty || leaf == "." || leaf == ".." { leaf = "attachment" }
    if !safeFormat.isEmpty && URL(fileURLWithPath: leaf).pathExtension.isEmpty {
      leaf += ".\(safeFormat)"
    }
    // Metadata files have reserved names.
    if ["note.md", "source.json"].contains(leaf) { leaf = "attachment-\(leaf)" }
    return directory.appending(path: leaf)
  }

  public func relativeAttachmentPath(_ url: URL) throws -> String {
    let prefix = root.path + "/"
    guard url.standardizedFileURL.path.hasPrefix(prefix) else {
      throw KnowledgeError.unsafePath
    }
    return String(url.standardizedFileURL.path.dropFirst(prefix.count))
  }

  public nonisolated func attachmentURL(for item: KnowledgeItem) -> URL? {
    guard item.attachment?.state == .saved, let path = item.attachment?.relativePath,
      !path.hasPrefix("/"), !path.split(separator: "/").contains("..")
    else { return nil }
    let url = root.appending(path: path).standardizedFileURL
    guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
      (try? Self.validatePrivateFile(url)) != nil
    else { return nil }
    return url
  }

  private func persist(_ item: KnowledgeItem) throws {
    guard item.id.count == 64, item.id.allSatisfy({ $0.isHexDigit }),
      item.original.conversationID == "filehelper"
    else { throw KnowledgeError.unsafePath }
    let directory = root.appending(path: "entries/\(item.id)")
    try Self.privateDirectory(directory)
    try Self.writePrivate(
      encoder.encode(item.original), to: directory.appending(path: "source.json"))
    try Self.writePrivate(Data(item.markdown.utf8), to: directory.appending(path: "note.md"))
    let statement = try database.prepare(
      "INSERT OR REPLACE INTO items (id,source,sent,kind,title,body,payload) VALUES (?,?,?,?,?,?,?)"
    )
    try statement.bind(item.id, at: 1)
    try statement.bind(item.sourceIdentity, at: 2)
    try statement.bind(Int64(item.sentAt.timeIntervalSince1970), at: 3)
    try statement.bind(item.kind.rawValue, at: 4)
    try statement.bind(item.title, at: 5)
    try statement.bind(item.body, at: 6)
    try statement.bind(String(decoding: encoder.encode(item), as: UTF8.self), at: 7)
    _ = try statement.step()
  }

  static func privateDirectory(_ url: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      let attrs = try manager.attributesOfItem(atPath: url.path)
      guard values.isDirectory == true, values.isSymbolicLink != true,
        (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
      else { throw KnowledgeError.unsafePath }
    } else {
      try manager.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  public static func validatePrivateFile(_ url: URL) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
    else { throw KnowledgeError.unsafePath }
  }

  static func writePrivate(_ data: Data, to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { try validatePrivateFile(url) }
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public enum KnowledgeError: Error, CustomStringConvertible {
  case unsafePath, missingKey, incompleteSource, invalidAttachment, syncBusy
  public var description: String {
    switch self {
    case .unsafePath: "知识库路径或权限不安全，请选择当前用户拥有的普通文件夹。"
    case .missingKey: "尚未找到微信数据库密钥，请先完成 GreenBubbles 密钥配置。"
    case .incompleteSource: "部分微信数据库无法读取。已读内容已保存，请修复后重新同步。"
    case .invalidAttachment: "附件读取或校验失败，原消息仍已保存。"
    case .syncBusy: "同步正在进行。"
    }
  }
}
