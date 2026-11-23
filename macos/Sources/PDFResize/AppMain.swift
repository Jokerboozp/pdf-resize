import SwiftUI
import AppKit
import PDFResizeCore

@main
enum PDFResizeEntryPoint {
    static func main() {
        if WorkerCLI.runIfRequested(arguments: CommandLine.arguments) {
            return
        }
        PDFResizeNativeApp.main()
    }
}

struct PDFResizeNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = BatchCoordinator()

    var body: some Scene {
        WindowGroup("PDF Resize") {
            MainWindowView(coordinator: coordinator)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear {
                    appDelegate.coordinator = coordinator
                }
        }
        .defaultSize(width: 1220, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文件夹或 PDF…") {
                    let urls = NativeFilePickers.pickSources()
                    if !urls.isEmpty {
                        coordinator.selectedSection = .workbench
                        coordinator.addSourceURLs(urls)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandMenu("压缩操作") {
                Button("开始批量压缩") {
                    coordinator.createAndStartJob()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(coordinator.sources.isEmpty)

                Button("重新扫描目录") {
                    coordinator.performScan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(coordinator.sources.isEmpty)

                Divider()

                Button("切换到批量压缩") { coordinator.selectedSection = .workbench }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("切换到画质对比") { coordinator.selectedSection = .compare }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("切换到任务队列") { coordinator.selectedSection = .jobs }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: BatchCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            coordinator?.selectedSection = .workbench
            coordinator?.addSourceURLs(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
