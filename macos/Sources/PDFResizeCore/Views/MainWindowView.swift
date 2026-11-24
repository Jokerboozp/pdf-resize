import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum NativeFilePickers {
    @MainActor
    public static func pickSources() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择要压缩的文件夹或 PDF 文件"
        panel.message = "可按住 Command (⌘) 一次选择多个文件夹（含外接硬盘）或多个 PDF 文件"
        panel.prompt = "添加"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .folder]
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    public static func pickSinglePDF() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择用于画质对比的 PDF 文件"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func pickDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "选定此文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

public struct MainWindowView: View {
    @ObservedObject var coordinator: BatchCoordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector: Bool = true
    @State private var isDropTargeted: Bool = false

    public init(coordinator: BatchCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 215, ideal: 238, max: 280)
        } detail: {
            ZStack {
                AmbientGlassCanvasBackground()

                Group {
                    switch coordinator.selectedSection {
                    case .workbench:
                        WorkbenchView(coordinator: coordinator, showInspector: $showInspector)
                    case .compare:
                        QualityCompareView(coordinator: coordinator)
                    case .jobs:
                        JobsMonitorView(coordinator: coordinator)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isDropTargeted {
                    dropOverlay
                }
            }
            .toolbar {
                mainToolbar
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .alert(coordinator.alertTitle, isPresented: $coordinator.isShowingAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(coordinator.alertMessage)
        }
    }

    // MARK: - Native Vibrancy Sidebar

    private var sidebarSelectionBinding: Binding<AppNavigationSection?> {
        Binding<AppNavigationSection?>(
            get: { coordinator.selectedSection },
            set: { newValue in
                if let newValue {
                    coordinator.selectedSection = newValue
                }
            }
        )
    }

    private var sidebarContent: some View {
        List(selection: sidebarSelectionBinding) {
            Section("工作空间") {
                ForEach(AppNavigationSection.allCases, id: \.self) { section in
                    NavigationLink(value: section) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.title)
                                    .font(.system(size: 13, weight: .medium))
                                Text(section.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: section.symbolName)
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .badge(section == .jobs && coordinator.runningJobsCount > 0 ? coordinator.runningJobsCount : 0)
                    .tag(section)
                }
            }

            if !coordinator.jobs.isEmpty {
                Section("最近任务") {
                    ForEach(coordinator.jobs.prefix(6)) { job in
                        Button {
                            coordinator.selectedJobID = job.id
                            coordinator.selectedSection = .jobs
                            coordinator.reloadSelectedJobFiles()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(statusDotColor(job.status))
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(job.stats.completedFiles)/\(job.stats.totalFiles) · 省 \(ByteFormat.string(job.stats.savedBytes))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarGlassFooter
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 4)
        }
    }

    private var sidebarGlassFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
                Text("累计已释放空间")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(ByteFormat.string(coordinator.lifetimeSavedBytes))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

            HStack(spacing: 5) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("\(ProcessInfo.processInfo.activeProcessorCount) 核 Apple Silicon/Intel · 已优化 \(coordinator.lifetimeOptimizedCount) 份")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 14, interactive: false)
    }

    // MARK: - Unified macOS Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(coordinator.selectedSection.title)
                    .font(.system(size: 14, weight: .semibold))
                if coordinator.runningJobsCount > 0 {
                    Text("正在高速处理 · \(ByteFormat.string(Int64(coordinator.bytesPerSecond)))/s")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if coordinator.selectedSection == .workbench {
                Button {
                    let picked = NativeFilePickers.pickSources()
                    if !picked.isEmpty {
                        coordinator.addSourceURLs(picked)
                    }
                } label: {
                    Label("添加文件或目录", systemImage: "folder.badge.plus")
                }
                .help("添加多个文件夹或 PDF 文件 (⌘O)")

                Button {
                    coordinator.performScan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.sources.isEmpty || coordinator.isScanning)
                .help("重新扫描并统计文件体积")

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        showInspector.toggle()
                    }
                } label: {
                    Label("参数检视器", systemImage: "sidebar.right")
                }
                .help("显示或隐藏右侧压缩参数检视器")
            } else if coordinator.selectedSection == .compare {
                Button {
                    if let url = NativeFilePickers.pickSinglePDF() {
                        coordinator.runQualityComparison(for: url)
                    }
                } label: {
                    Label("选择对比文件", systemImage: "doc.badge.plus")
                }

                Button {
                    coordinator.runQualityComparison()
                } label: {
                    Label("重新试压", systemImage: "sparkles")
                }
                .disabled(coordinator.compareSourceURL == nil || coordinator.isComparing)
            } else if coordinator.selectedSection == .jobs {
                Button {
                    coordinator.refreshJobs()
                    coordinator.reloadSelectedJobFiles()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Finder Drop Overlay

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 42, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                Text("松开鼠标以导入文件夹或 PDF")
                    .font(.system(size: 17, weight: .semibold))
                Text("自动递归扫描全部子目录并去重")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .liquidGlassCard(cornerRadius: 22)
        }
        .padding(20)
        .transition(.opacity)
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let lock = NSLock()
        var collected: [URL] = []
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !collected.isEmpty {
                if coordinator.selectedSection == .compare, let firstPDF = collected.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                    coordinator.runQualityComparison(for: firstPDF)
                } else {
                    coordinator.selectedSection = .workbench
                    coordinator.addSourceURLs(collected)
                }
            }
        }
        return true
    }

    private func statusDotColor(_ status: JobStatus) -> Color {
        switch status {
        case .running, .created: return .blue
        case .completed: return .green
        case .paused: return .orange
        case .cancelled, .failed: return .red
        }
    }
}
