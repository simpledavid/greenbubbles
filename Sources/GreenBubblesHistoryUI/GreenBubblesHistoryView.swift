import SwiftUI

public struct GreenBubblesHistoryView: View {
  @State private var model: HistoryBrowserModel
  public init(model: HistoryBrowserModel? = nil) {
    _model = State(initialValue: model ?? HistoryBrowserModel(arguments: []))
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("读取微信 / 打开备份") { model.presentDirectConnection() }
        Button("创建加密备份") { model.presentSnapshotCreation() }
        Button("打开导出记录") { model.chooseBundle() }
        Spacer()
        Button("关闭记录") { model.closeBundle() }.disabled(!model.hasOpenHistory)
      }
      .padding(12)
      Divider()
      HistoryRootView(model: model)
    }
  }
}
