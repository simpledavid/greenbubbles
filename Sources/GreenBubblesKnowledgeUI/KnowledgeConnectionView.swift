import AppKit
import SwiftUI

struct KnowledgeConnectionView: View {
  @Bindable var model: KnowledgeAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var isSaving = false
  @State private var executable = ""
  @State private var source = ""
  @State private var key = ""
  @State private var library = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("连接文件传输助手").font(.title2.weight(.semibold))
        Text("只收集文件传输助手。原文与附件保存在本地，关闭微信后仍可查看。")
          .foregroundStyle(.secondary)
      }
      Form {
        Section("微信读取") {
          pathRow("读取工具", path: $executable, directories: false)
          pathRow("数据目录", path: $source, directories: true)
          Button("自动查找微信数据目录") {
            if let found = model.discoverSource() { source = found }
          }
          pathRow("密钥文件", path: $key, directories: false)
          Text("选择已有的 passphrase.txt 文件。密钥只供本地读取，不会写进知识库。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("知识库") {
          pathRow("保存位置", path: $library, directories: true)
          Text("每条内容保留 Markdown 原文、消息来源和独立附件副本。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      Label("首次使用需要按 GreenBubbles 文档配置微信数据库密钥。", systemImage: "key")
        .font(.callout)
      Link(
        "查看首次配置说明",
        destination: URL(
          string:
            "https://github.com/bojieli/greenbubbles/blob/main/docs/PASSPHRASE_ACQUISITION.md")!)
      if let error = model.error {
        Text(error).font(.callout).foregroundStyle(.red)
      }
      HStack {
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(isSaving ? "保存中…" : "保存并同步") {
          isSaving = true
          Task {
            if await model.saveConnection(
              executable: executable, source: source, key: key, library: library)
            {
              dismiss()
              model.sync()
            }
            isSaving = false
          }
        }
        .buttonStyle(.borderedProminent).disabled(isSaving)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(26).frame(width: 720, height: 620)
    .onAppear {
      executable = model.executablePath
      source = model.sourcePath
      key = model.keyPath
      library = model.libraryPath
    }
  }

  private func pathRow(_ title: String, path: Binding<String>, directories: Bool) -> some View {
    HStack {
      TextField(title, text: path).textFieldStyle(.roundedBorder)
      Button("选择…") {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.canCreateDirectories = directories
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
      }
    }
  }
}
