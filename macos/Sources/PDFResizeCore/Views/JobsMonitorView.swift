import SwiftUI
import AppKit

public struct JobsMonitorView: View {
    @ObservedObject var coordinator: BatchCoordinator
    @State private var selectedRowID: JobFileRow.ID?

    public init(coordinator: BatchCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if let job = coordinator.selectedJob {
                VStack(spacing: 14) {
                    telemetryHeader(job)
                    filterAndSearchBar(job)
                    filesNativeTable
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)
            } else {
                emptyJobsView
            }
        }
    }

    // MARK: - Top Liquid Glass Telemetry Header

    private func telemetryHeader(_ job: JobRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(coordinator.jobs) { item in
                        Button {
                            coordinator.selectedJobID = item.id
                            coordinator.reloadSelectedJobFiles()
                        } label: {
                            Text("\(item.name) — \(item.status.displayTitle)")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(job.name)
                            .font(.system(size: 16, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                statusBadge(job.status)

                Text(job.outputMode.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                Spacer()

                AdaptiveGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        if job.status == .running {
                            Button {
                                coordinator.pauseJob(job.id)
                            } label: {
                                Label("暂停", systemImage: "pause.fill")
                            }
                            .adaptiveGlassButton()
                        }

                        if job.status == .paused || job.status == .created {
                            Button {
                                coordinator.startJob(jobID: job.id)
                            } label: {
                                Label("继续", systemImage: "play.fill")
                            }
                            .adaptiveGlassButton(prominent: true)
                        }

                        if job.stats.failed > 0 && job.status != .running {
                            Button {
                                coordinator.retryFailed(job.id)
                            } label: {
                                Label("重试失败 (\(job.stats.failed))", systemImage: "arrow.clockwise")
                            }
                            .adaptiveGlassButton()
                        }

                        if job.status == .running || job.status == .paused {
                            Button(role: .destructive) {
                                coordinator.cancelJob(job.id)
                            } label: {
                                Text("取消")
                            }
                            .adaptiveGlassButton()
                        }

                        Button {
                            revealJobFolder(job)
                        } label: {
                            Label("访达显示", systemImage: "folder")
                        }
                        .adaptiveGlassButton()

                        if job.status != .running {
                            Button(role: .destructive) {
                                coordinator.deleteJob(job.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除此任务记录（不会删除磁盘上的 PDF 文件）")
                        }
                    }
                    .controlSize(.small)
                }
            }

            // Progress bar
            VStack(spacing: 6) {
                HStack {
                    Text(String(format: "体积进度 %.1f%%", job.stats.progressByBytes * 100.0))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Text("\(job.stats.completedFiles) / \(job.stats.totalFiles) 个文件")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: job.stats.progressByBytes)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }

            // 4 KPI Pods
            HStack(spacing: 12) {
                kpiPod(
                    title: "已释放空间",
                    value: ByteFormat.string(job.stats.savedBytes),
                    sub: String(format: "平均压缩 -%.1f%%", job.stats.savingPercent),
                    accent: .green
                )
                kpiPod(
                    title: "处理前后对比",
                    value: "\(ByteFormat.string(job.stats.processedOriginalBytes)) → \(ByteFormat.string(job.stats.processedNewBytes))",
                    sub: "总源体积 \(ByteFormat.string(job.stats.totalOriginalBytes))",
                    accent: .primary
                )
                kpiPod(
                    title: "实时吞吐速度",
                    value: job.status == .running ? "\(ByteFormat.string(Int64(coordinator.bytesPerSecond)))/s" : "—",
                    sub: job.status == .running ? "预计剩余 \(ByteFormat.etaString(coordinator.etaSeconds))" : job.status.displayTitle,
                    accent: .cyan
                )
                kpiPod(
                    title: "完成统计",
                    value: "成功 \(job.stats.done) · 跳过 \(job.stats.skipped)",
                    sub: "待处理 \(job.stats.pending) · 失败 \(job.stats.failed)",
                    accent: job.stats.failed > 0 ? .orange : .primary
                )
            }

            if !coordinator.activeFileNames.isEmpty && job.status == .running {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在处理：")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text(coordinator.activeFileNames.prefix(5).joined(separator: "  ·  "))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 18)
    }

    private func kpiPod(title: String, value: String, sub: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .monospacedDigit()
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Filter & Search Bar

    private func filterAndSearchBar(_ job: JobRecord) -> some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: $coordinator.fileStatusFilter) {
                Text("全部 (\(job.stats.totalFiles))").tag("all")
                Text("已优化 (\(job.stats.done))").tag("done")
                Text("已跳过 (\(job.stats.skipped))").tag("skipped")
                Text("失败 (\(job.stats.failed))").tag("failed")
                Text("等待中 (\(job.stats.pending))").tag("pending")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .onChange(of: coordinator.fileStatusFilter) { _, _ in
                coordinator.reloadSelectedJobFiles()
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("搜索文件名或路径…", text: $coordinator.fileSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onChange(of: coordinator.fileSearchQuery) { _, _ in
                        coordinator.reloadSelectedJobFiles()
                    }
                if !coordinator.fileSearchQuery.isEmpty {
                    Button {
                        coordinator.fileSearchQuery = ""
                        coordinator.reloadSelectedJobFiles()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 220)
            .liquidGlassCapsule()
        }
    }

    // MARK: - Native Virtualized macOS Table (Handles 3000+ rows effortlessly)

    private var filesNativeTable: some View {
        Table(coordinator.selectedJobFiles, selection: $selectedRowID) {
            TableColumn("文件路径") { row in
                HStack(spacing: 7) {
                    Image(systemName: "doc.richtext.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text(row.relativePath)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.sourcePath)
                }
            }
            .width(min: 220, ideal: 340)

            TableColumn("原始大小") { row in
                Text(ByteFormat.string(row.originalSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 95, max: 120)

            TableColumn("优化后") { row in
                Text(row.newSize.map { ByteFormat.string($0) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 95, max: 120)

            TableColumn("节省空间") { row in
                if row.savedBytes > 0 {
                    Text("\(ByteFormat.string(row.savedBytes)) (-\(String(format: "%.1f", row.savingPercent))%)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 110, ideal: 140, max: 180)

            TableColumn("耗时") { row in
                if let ms = row.durationMs {
                    Text(String(format: "%.2fs", Double(ms) / 1000.0))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 55, ideal: 70, max: 90)

            TableColumn("状态") { row in
                HStack(spacing: 4) {
                    fileStatusPill(row.status)
                    if let err = row.errorMessage, !err.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 11))
                            .help(err)
                    }
                }
            }
            .width(min: 85, ideal: 105, max: 140)
        }
        .contextMenu(forSelectionType: JobFileRow.ID.self) { ids in
            if let firstID = ids.first,
               let row = coordinator.selectedJobFiles.first(where: { $0.id == firstID }) {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([row.effectiveURL])
                }
                Button("使用“预览”打开") {
                    NSWorkspace.shared.open(row.effectiveURL)
                }
                Button("移入画质对比") {
                    coordinator.selectedSection = .compare
                    coordinator.runQualityComparison(for: URL(fileURLWithPath: row.sourcePath))
                }
            }
        } primaryAction: { ids in
            if let firstID = ids.first,
               let row = coordinator.selectedJobFiles.first(where: { $0.id == firstID }) {
                NSWorkspace.shared.open(row.effectiveURL)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .liquidGlassCard(cornerRadius: 14)
    }

    private var emptyJobsView: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("暂无压缩任务记录")
                .font(.system(size: 16, weight: .semibold))
            Button("前往批量压缩工作台") {
                coordinator.selectedSection = .workbench
            }
            .adaptiveGlassButton(prominent: true)
        }
        .padding(36)
        .liquidGlassCard(cornerRadius: 20)
    }

    private func statusBadge(_ status: JobStatus) -> some View {
        let color: Color = {
            switch status {
            case .running, .created: return .blue
            case .completed: return .green
            case .paused: return .orange
            case .cancelled, .failed: return .red
            }
        }()
        return Text(status.displayTitle)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func fileStatusPill(_ status: FileProcessStatus) -> some View {
        let color: Color = {
            switch status {
            case .done: return .green
            case .processing: return .blue
            case .pending: return .secondary
            case .failed: return .red
            default: return .orange
            }
        }()
        return Text(status.displayTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func revealJobFolder(_ job: JobRecord) {
        if let outDir = job.outputDir {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outDir)
            return
        }
        let firstSource = job.sourceSummary.components(separatedBy: " ; ").first ?? ""
        if !firstSource.isEmpty {
            let url = URL(fileURLWithPath: firstSource)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}
