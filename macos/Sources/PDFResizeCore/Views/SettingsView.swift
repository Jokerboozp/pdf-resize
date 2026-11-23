import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var coordinator: BatchCoordinator
    @State private var clearedCountMessage: String?

    public init(coordinator: BatchCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Form {
            Section("性能与通知") {
                Stepper(
                    "默认并行进程数：\(coordinator.config.workers)",
                    value: $coordinator.config.workers,
                    in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)
                )
                Toggle("批量压缩完成时发送 macOS 系统通知", isOn: $coordinator.sendNotificationOnComplete)
            }

            Section("增量跳过指纹库") {
                Text("原地优化后的 PDF 会记录体积与修改时间指纹，重复扫描时自动秒跳过。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    Button("重置跳过缓存") {
                        let removed = coordinator.clearOptimizationCache()
                        clearedCountMessage = "已清空 \(removed) 条历史指纹"
                    }
                    if let msg = clearedCountMessage {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("存储位置") {
                HStack {
                    Text("任务数据库")
                    Spacer()
                    Text(coordinator.store.dbURL.path)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([coordinator.store.dbURL])
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 310)
    }
}
