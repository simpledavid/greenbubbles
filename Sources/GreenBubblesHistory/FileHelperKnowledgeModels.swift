import CryptoKit
import Foundation

public enum KnowledgeKind: String, Codable, CaseIterable, Sendable {
  case text, link, image, file, video, voice, other

  public var title: String {
    switch self {
    case .text: "文字"
    case .link: "链接"
    case .image: "图片"
    case .file: "文件"
    case .video: "视频"
    case .voice: "语音"
    case .other: "其他"
    }
  }

  public var systemImage: String {
    switch self {
    case .text: "text.alignleft"
    case .link: "link"
    case .image: "photo"
    case .file: "doc"
    case .video: "video"
    case .voice: "waveform"
    case .other: "tray"
    }
  }

  public var attachmentKind: String? {
    switch self {
    case .image: "image"
    case .file: "document"
    case .video: "video"
    case .voice: "voice"
    default: nil
    }
  }
}

public struct KnowledgeAttachment: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case pending, saved, unavailable, failed }
  public var state: State
  public var name: String
  public var relativePath: String?
  public var sha256: String?
  public var detail: String?
  public var lastAttempt: Date?
}

public struct KnowledgeItem: Codable, Identifiable, Sendable {
  public let id: String
  public let sourceIdentity: String
  public let messageID: String
  public let sentAt: Date
  public let kind: KnowledgeKind
  public let title: String
  public let body: String
  public let links: [String]
  public let original: HistoryDirectMessage
  public var attachment: KnowledgeAttachment?

  public static func project(
    _ message: HistoryDirectMessage, sourceIdentity: String
  ) -> KnowledgeItem? {
    // File Helper is the sole capture surface. System and recall notices are
    // not user submissions; unsupported user payloads are retained as evidence.
    guard message.conversationID == "filehelper", message.messageType != 10000,
      message.messageType != 10002, message.sender != "filehelper"
    else { return nil }
    let object: [String: HistoryDirectJSONValue]
    if case .object(let value) = message.content { object = value } else { object = [:] }
    let variant = object.keys.sorted().first ?? "Unknown"
    let kind: KnowledgeKind
    switch variant {
    case "Text", "Quote": kind = .text
    case "Link", "MiniProgram", "ChannelVideo": kind = .link
    case "Image": kind = .image
    case "File": kind = .file
    case "Video": kind = .video
    case "Voice": kind = .voice
    default: kind = .other
    }
    var fields: [String: HistoryDirectJSONValue] = [:]
    if case .object(let values)? = object[variant] { fields = values }
    func text(_ key: String) -> String? {
      guard case .string(let value)? = fields[key], !value.isEmpty else { return nil }
      return value
    }
    let body: String
    if case .string(let value)? = object["Text"] {
      body = value
    } else {
      let parts = [text("title"), text("description"), text("content"), text("url")]
        .compactMap { $0 }
      body = parts.isEmpty ? message.displayText : parts.joined(separator: "\n\n")
    }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var seen = Set<String>()
    let links = (detector?.matches(in: body, range: NSRange(body.startIndex..., in: body)) ?? [])
      .compactMap(\.url)
      .filter { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
      .map(\.absoluteString).filter { seen.insert($0).inserted }
    let resolvedKind: KnowledgeKind = kind == .text && !links.isEmpty ? .link : kind
    let headline =
      text("title") ?? body.split(whereSeparator: \.isNewline).first.map(String.init)
      ?? kind.title
    let title = String(
      headline.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(90))
    let id = SHA256.hash(data: Data("\(sourceIdentity)\u{0}\(message.id)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let attachment = kind.attachmentKind.map { _ in
      KnowledgeAttachment(
        state: .pending, name: text("title") ?? kind.title, relativePath: nil,
        sha256: nil, detail: nil)
    }
    return KnowledgeItem(
      id: id, sourceIdentity: sourceIdentity, messageID: message.id,
      sentAt: message.createdAt, kind: resolvedKind, title: title, body: body,
      links: links, original: message, attachment: attachment)
  }

  public var markdown: String {
    let time = sentAt.formatted(date: .numeric, time: .standard)
    var result = "# \(title)\n\n来源：微信文件传输助手\n发送时间：\(time)\n\n\(body)\n"
    if let path = attachment?.relativePath {
      let label = (attachment?.name ?? "附件").replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        .split(whereSeparator: \.isNewline).joined(separator: " ")
      let leaf =
        URL(fileURLWithPath: path).lastPathComponent
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
      result += "\n附件：[\(label)](\(leaf))\n"
    }
    if original.contentTruncated { result += "\n> 原消息超出读取上限，正文可能不完整。\n" }
    return result
  }
}

public struct KnowledgeSyncState: Codable, Sendable {
  public var backfillCursor: String?
  // A queue also preserves gaps created while newer messages arrive during a
  // bounded import. Optional for libraries written before this field existed.
  public var pendingCursors: [String]?
  public var backfillComplete = false
  public var lastSync: Date?
  public init() {}
}

public struct KnowledgeSummary: Sendable {
  public let total: Int
  public let attachments: Int
}
