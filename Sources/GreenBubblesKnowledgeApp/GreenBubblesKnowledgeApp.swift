import AppKit
import GreenBubblesKnowledgeUI
import SwiftUI

@main
struct GreenBubblesKnowledgeApplication: App {
  @NSApplicationDelegateAdaptor(KnowledgeAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup("文件传输助手 · 知识库") {
      FileHelperKnowledgeView()
        .frame(minWidth: 1050, minHeight: 700)
    }
    .defaultSize(width: 1280, height: 820)
  }
}

@MainActor
final class KnowledgeAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
