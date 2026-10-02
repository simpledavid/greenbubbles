import SwiftUI

/// Embeddable local knowledge library. No source is queried until the user
/// connects a source and starts synchronization in this view.
public struct FileHelperKnowledgeView: View {
  @State private var model: KnowledgeAppModel

  public init(storageName: String = "GreenBubblesKnowledge") {
    _model = State(initialValue: KnowledgeAppModel(storageName: storageName))
  }

  /// Keep this model in the host app when switching between workspace tabs.
  public init(model: KnowledgeAppModel) {
    _model = State(initialValue: model)
  }

  public var body: some View { KnowledgeRootView(model: model) }
}
