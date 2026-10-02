import AppKit
import GreenBubblesHistory
import SwiftUI

private let knowledgeAccent = Color(red: 0.16, green: 0.46, blue: 0.36)

struct KnowledgeRootView: View {
  @Bindable var model: KnowledgeAppModel

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
    } content: {
      VStack(spacing: 0) {
        collectionHeader
        if model.items.isEmpty {
          emptyCollection
        } else {
          List(selection: $model.selectedID) {
            ForEach(model.items) { item in
              KnowledgeRow(item: item).tag(item.id)
            }
            if model.hasMore {
              Button("加载更多") { Task { await model.reload(loadMore: true) } }
                .buttonStyle(.borderless)
            }
          }
          .listStyle(.plain)
        }
        syncFooter
      }
      .navigationSplitViewColumnWidth(min: 320, ideal: 410, max: 500)
    } detail: {
      if let item = model.selectedItem {
        KnowledgeDetailView(item: item, model: model)
      } else {
        ContentUnavailableView(
          "在这里查看收藏", systemImage: "doc.text.magnifyingglass",
          description: Text("选一条内容，查看原文、链接和保存的附件。"))
      }
    }
    .tint(knowledgeAccent)
    .toolbar {
      ToolbarItemGroup {
        if model.isSyncing {
          ProgressView().controlSize(.small)
          Button("停止") { model.stopSync() }
        } else {
          Button {
            model.sync()
          } label: {
            Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(model.isDemo)
        }
        Button {
          model.sheet = .connection
        } label: {
          Label("连接设置", systemImage: "gearshape")
        }
      }
    }
    .sheet(item: $model.sheet) { _ in KnowledgeConnectionView(model: model) }
    .task { await model.start() }
    .task(id: model.query) {
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      await model.reload()
    }
    .onChange(of: model.filter) { _, _ in Task { await model.reload() } }
    .onChange(of: model.autoSync) { _, _ in model.setAutoSync() }
    .alert(
      "需要处理",
      isPresented: Binding(
        get: { model.error != nil },
        set: {
          if !$0 { model.error = nil }
        })
    ) {
      Button("知道了") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "tray.and.arrow.down.fill")
          .font(.title2).foregroundStyle(knowledgeAccent)
          .padding(12).background(
            knowledgeAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        VStack(alignment: .leading, spacing: 4) {
          Text("我的知识库").font(.title3.weight(.semibold))
          Text("从文件传输助手收集").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 16)
      VStack(spacing: 3) {
        filterButton(title: "全部内容", icon: "square.stack", kind: nil)
        ForEach(KnowledgeKind.allCases, id: \.self) { kind in
          filterButton(title: kind.title, icon: kind.systemImage, kind: kind)
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Text("已归档").font(.caption).foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text("\(model.total)").font(.system(size: 32, weight: .semibold, design: .rounded))
          Text("条内容").font(.caption).foregroundStyle(.secondary)
        }
        Text("\(model.attachmentCount) 条带附件").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if model.isDemo {
        Label("合成示例数据", systemImage: "sparkles")
          .font(.caption).foregroundStyle(.orange)
      }
      Toggle("自动同步", isOn: $model.autoSync).toggleStyle(.switch).disabled(model.isDemo)
      Text("打开工作区后，应用运行期间每 30 秒检查新内容。")
        .font(.caption2).foregroundStyle(.secondary)
      Button {
        model.revealLibrary()
      } label: {
        Label("打开知识库文件夹", systemImage: "folder")
      }
      .buttonStyle(.borderless)
      .font(.callout)
      Label("保存在这台 Mac", systemImage: "lock.shield")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(18)
  }

  private func filterButton(title: String, icon: String, kind: KnowledgeKind?) -> some View {
    Button {
      model.filter = kind
    } label: {
      HStack {
        Image(systemName: icon).frame(width: 22)
        Text(title)
        Spacer()
        if kind == nil { Text("\(model.total)").font(.caption.monospacedDigit()) }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .foregroundStyle(model.filter == kind ? knowledgeAccent : .primary)
      .background(
        model.filter == kind ? knowledgeAccent.opacity(0.10) : .clear,
        in: RoundedRectangle(cornerRadius: 9)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var collectionHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(model.filter?.title ?? "全部内容").font(.title2.weight(.semibold))
        Spacer()
        Text("\(model.items.count) 条").font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索原文、链接或文件名", text: $model.query).textFieldStyle(.plain)
          .accessibilityIdentifier("knowledge.search")
        if !model.query.isEmpty {
          Button {
            model.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary)
        }
      }
      .padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }
    .padding(18)
  }

  private var emptyCollection: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
        .font(.system(size: 42, weight: .light)).foregroundStyle(knowledgeAccent.opacity(0.65))
      Text(model.query.isEmpty ? "留住值得保存的内容" : "没有找到匹配内容")
        .font(.title3.weight(.semibold))
      Text(model.query.isEmpty ? "发到文件传输助手，\n在这里收集、搜索和查看。" : "换个关键词，或选择全部内容。")
        .multilineTextAlignment(.center).foregroundStyle(.secondary)
      if model.total == 0 {
        Button("连接微信") { model.sheet = .connection }.buttonStyle(.borderedProminent)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var syncFooter: some View {
    HStack(spacing: 8) {
      Circle().fill(model.isSyncing ? .orange : knowledgeAccent).frame(width: 6, height: 6)
      Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      Spacer(minLength: 0)
    }
    .padding(14).background(.bar)
  }
}

private struct KnowledgeRow: View {
  let item: KnowledgeItem
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: item.kind.systemImage)
        .foregroundStyle(knowledgeAccent).frame(width: 32, height: 32)
        .background(knowledgeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 7) {
        Text(item.title).font(.body.weight(.medium)).lineLimit(2)
        Text(item.body).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        HStack {
          Text(item.sentAt, format: .dateTime.year().month().day())
          Spacer()
          Text(item.kind.title)
          if item.attachment?.state == .saved { Image(systemName: "checkmark.circle") }
        }
        .font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 12)
  }
}

private struct KnowledgeDetailView: View {
  let item: KnowledgeItem
  let model: KnowledgeAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Label(item.kind.title, systemImage: item.kind.systemImage)
            .font(.caption.weight(.medium)).foregroundStyle(knowledgeAccent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(knowledgeAccent.opacity(0.08), in: Capsule())
          Spacer()
          Button {
            model.copy(item.body)
          } label: {
            Label("复制", systemImage: "doc.on.doc")
          }
          .buttonStyle(.borderless)
        }
        VStack(alignment: .leading, spacing: 12) {
          Text(item.title).font(.system(size: 27, weight: .semibold)).textSelection(.enabled)
          Label(item.sentAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
            .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text(item.body).font(.body).lineSpacing(7).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !item.links.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            Text("链接").font(.headline)
            ForEach(item.links, id: \.self) { value in
              if let url = URL(string: value) {
                Link(destination: url) {
                  HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text(value).lineLimit(2)
                    Spacer()
                  }
                  .padding(12).background(
                    .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
              }
            }
          }
        }
        if let attachment = item.attachment {
          VStack(alignment: .leading, spacing: 12) {
            Text("附件").font(.headline)
            HStack(spacing: 12) {
              Image(systemName: item.kind.systemImage).font(.title2).foregroundStyle(
                knowledgeAccent)
              VStack(alignment: .leading, spacing: 5) {
                Text(attachment.name).font(.callout.weight(.medium))
                Text(attachment.state == .saved ? "已独立保存到知识库" : attachment.detail ?? "等待保存")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if attachment.state == .saved {
                Button("打开") { model.openAttachment(item) }.buttonStyle(.bordered)
              }
            }
            .padding(16).background(
              .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            if attachment.state != .saved {
              Button("重试保存附件") { model.sync(retryAttachments: true) }
                .disabled(model.isSyncing || model.isDemo)
            }
          }
        }
        if item.original.contentTruncated || item.original.contentDecodeState != "decoded" {
          Label("原消息可能未完整解码，请对照微信确认。", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        }
        Spacer(minLength: 16)
        Divider()
        HStack {
          Label("来源 · 文件传输助手", systemImage: "bubble.left")
          Spacer()
          Button("查看保存文件") { model.revealEntry(item) }.buttonStyle(.borderless)
        }
        .font(.caption).foregroundStyle(.secondary)
      }
      .padding(32)
    }
  }
}
