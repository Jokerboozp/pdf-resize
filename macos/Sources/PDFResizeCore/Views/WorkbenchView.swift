import SwiftUI
import AppKit

public struct WorkbenchView: View {
    @ObservedObject var coordinator: BatchCoordinator
    @Binding var showInspector: Bool
    @State private var showInplaceConfirm: Bool = false

    public init(coordinator: BatchCoordinator, showInspector: Binding<Bool>) {
        self.coordinator = coordinator
        self._showInspector = showInspector
    }

    public var body: some View {
        centerStage
            .inspector(isPresented: $showInspector) {
                inspectorPane
                    .inspectorColumnWidth(min: 295, ideal: 330, max: 390)
            }
            .confirmationDialog(
                "确认直接原地优化原文件？",
                isPresented: $showInplaceConfirm,
                titleVisibility: .visible
            ) {
                Button("开始原地优化", role: .destructive) {
                    coordinator.createAndStartJob()
                }
                Button("先选择备份文件夹…") {
                    if let bkp = NativeFilePickers.pickDirectory(title: "选择原文件自动备份文件夹") {
                        coordinator.backupDirectoryURL = bkp
                        coordinator.createAndStartJob()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前未设置备份文件夹，将直接优化所选目录中的 PDF。系统已开启同盘临时写入、页数完整性校验与变大自动跳过保护。")
            }
    }

    // MARK: - Center Stage (Drop Well or Source Directory Canvas)

    private var centerStage: some View {
        ZStack(alignment: .bottom) {
            if coordinator.sources.isEmpty {
                emptyDropStage
            } else {
                populatedSourceStage
            }

            floatingGlassActionBar
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
    }

    private var emptyDropStage: some View {
        VStack(spacing: 22) {
            Spacer()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 84, height: 84)
                    Image(systemName: "doc.badge.gearshape.fill")
                        .font(.system(size: 38, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 6) {
                    Text("拖入文件夹或 PDF 开始批量瘦身")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("专为 60GB+ · 3000+ 海量文档打造 · 支持跨硬盘多文件夹合并与原地无损替换")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                AdaptiveGlassGroup(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            let urls = NativeFilePickers.pickSources()
                            if !urls.isEmpty {
                                coordinator.addSourceURLs(urls)
                            }
                        } label: {
                            Label("选择文件夹或 PDF…", systemImage: "folder.badge.plus")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                        }
                        .adaptiveGlassButton(prominent: true)
                        .keyboardShortcut("o", modifiers: [.command])

                        Button {
                            if let pdf = NativeFilePickers.pickSinglePDF() {
                                coordinator.selectedSection = .compare
                                coordinator.runQualityComparison(for: pdf)
                            }
                        } label: {
                            Label("单文件画质对比…", systemImage: "rectangle.lefthalf.inset.filled.arrow.left")
                                .font(.system(size: 13.5, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                        .adaptiveGlassButton(prominent: false)
                    }
                }

                HStack(spacing: 18) {
                    featurePill(icon: "checkmark.shield.fill", color: .green, text: "同盘原子写入")
                    featurePill(icon: "text.magnifyingglass", color: .cyan, text: "100% 保留可选中矢量文字")
                    featurePill(icon: "cpu.fill", color: .indigo, text: "多进程隔离防内存溢出")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 42)
            .padding(.vertical, 38)
            .liquidGlassCard(cornerRadius: 24)

            Spacer()
            Spacer().frame(height: 56)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featurePill(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 11.5))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var populatedSourceStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Scan Summary Glass Strip
                scanSummaryGlassCard

                // Header bar for folder list
                HStack {
                    Label("待处理源列表（\(coordinator.sources.count) 项）", systemImage: "tray.full.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Toggle("包含子文件夹", isOn: $coordinator.recursiveScan)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .onChange(of: coordinator.recursiveScan) { _, _ in
                            coordinator.performScan()
                        }

                    Button("继续添加…") {
                        let urls = NativeFilePickers.pickSources()
                        if !urls.isEmpty {
                            coordinator.addSourceURLs(urls)
                        }
                    }
                    .controlSize(.small)

                    Button("清空", role: .destructive) {
                        coordinator.clearSources()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 4)

                // Authentic Finder-icon cards for each folder / file
                LazyVStack(spacing: 8) {
                    ForEach(coordinator.sources) { item in
                        sourceRowCard(item)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 100)
        }
    }

    private var scanSummaryGlassCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                if coordinator.isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在高速扫描目录与文件指纹…")
                            .font(.system(size: 13, weight: .medium))
                    }
                } else if let scan = coordinator.lastScanSummary {
                    metricColumn(label: "发现 PDF", value: "\(scan.totalFiles)", tint: .primary)
                    Divider().frame(height: 28)
                    metricColumn(label: "原始总体积", value: ByteFormat.string(scan.totalBytes), tint: .primary)
                    Divider().frame(height: 28)
                    metricColumn(label: "待优化", value: "\(scan.pendingCount)", tint: .accentColor)
                    Divider().frame(height: 28)
                    metricColumn(label: "自动跳过", value: "\(scan.alreadyOptimizedCount + scan.tooSmallCount)", tint: .secondary)
                } else {
                    Text("已添加路径，点击右上角「重新扫描」统计详情")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let scan = coordinator.lastScanSummary, !scan.largestSamples.isEmpty {
                    Menu {
                        ForEach(scan.largestSamples.prefix(12), id: \.sourceURL.path) { sample in
                            Button("\(sample.relativePath) (\(ByteFormat.string(sample.originalSize)))") {
                                coordinator.selectedSection = .compare
                                coordinator.runQualityComparison(for: sample.sourceURL)
                            }
                        }
                    } label: {
                        Label("抽样对比画质", systemImage: "eye.fill")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .liquidGlassCard(cornerRadius: 16)
    }

    private func metricColumn(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    private func sourceRowCard(_ item: SourceItem) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(item.url.path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let count = item.scannedCount, let bytes = item.scannedBytes {
                Text("\(count) 个 PDF · \(ByteFormat.string(bytes))")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在访达中显示")

            Button {
                coordinator.removeSource(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("从列表移除")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlassCard(cornerRadius: 13)
    }

    // MARK: - Floating Liquid Glass Bottom Action Bar

    private var floatingGlassActionBar: some View {
        AdaptiveGlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 1) {
                    Text(actionSummaryHeadline)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(actionSummarySubline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    triggerStart()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                        Text(startButtonTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .adaptiveGlassButton(prominent: true)
                .disabled(coordinator.sources.isEmpty)
                .keyboardShortcut("r", modifiers: [.command])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .liquidGlassCapsule(prominence: .regular)
        }
    }

    private var actionSummaryHeadline: String {
        guard !coordinator.sources.isEmpty else {
            return "等待添加文件夹或 PDF 文档"
        }
        let limitVal = Int(coordinator.trialLimitText.trimmingCharacters(in: .whitespaces))
        let limitSuffix = (limitVal != nil && limitVal! > 0) ? " · 仅试跑前 \(limitVal!) 个" : ""
        if let scan = coordinator.lastScanSummary {
            return "就绪：\(scan.pendingCount) 个待压缩 PDF（共 \(ByteFormat.string(scan.totalBytes))）\(limitSuffix)"
        }
        return "已选 \(coordinator.sources.count) 个路径\(limitSuffix)"
    }

    private var actionSummarySubline: String {
        let cfg = coordinator.config
        let presetPart = cfg.preset.title
        let detailPart = cfg.compressImages ? "\(cfg.downsampleImages ? "\(cfg.targetDPI) DPI" : "原尺寸") · 质量 \(cfg.jpegQuality)%\(cfg.grayscale ? " · 灰度" : "")" : "无损结构清理"
        let modePart = coordinator.outputMode.title
        return "\(presetPart)（\(detailPart)） · \(modePart) · \(cfg.workers) 核并行"
    }

    private var startButtonTitle: String {
        if let n = Int(coordinator.trialLimitText.trimmingCharacters(in: .whitespaces)), n > 0 {
            return "试跑前 \(n) 个"
        }
        return coordinator.outputMode == .inplace ? "开始原地优化" : "开始压缩导出"
    }

    private func triggerStart() {
        if coordinator.outputMode == .inplace && coordinator.backupDirectoryURL == nil {
            showInplaceConfirm = true
        } else {
            coordinator.createAndStartJob()
        }
    }

    // MARK: - Right Native macOS Inspector

    private var inspectorPane: some View {
        Form {
            Section("压缩强度预设") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(CompressionPreset.selectablePresets) { preset in
                        presetTile(preset)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("图像与色彩微调") {
                Toggle("重编码与优化图像", isOn: Binding(
                    get: { coordinator.config.compressImages },
                    set: { val in
                        coordinator.config.compressImages = val
                        coordinator.config.preset = .custom
                    }
                ))

                if coordinator.config.compressImages {
                    Toggle("缩放高分辨率图像", isOn: Binding(
                        get: { coordinator.config.downsampleImages },
                        set: { val in
                            coordinator.config.downsampleImages = val
                            coordinator.config.preset = .custom
                        }
                    ))

                    if coordinator.config.downsampleImages {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("目标分辨率")
                                Spacer()
                                Text("\(coordinator.config.targetDPI) DPI")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(coordinator.config.targetDPI) },
                                    set: { val in
                                        coordinator.config.targetDPI = Int((val / 5.0).rounded() * 5.0)
                                        coordinator.config.preset = .custom
                                    }
                                ),
                                in: 50...300
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("JPEG 质量")
                            Spacer()
                            Text("\(coordinator.config.jpegQuality)%")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(coordinator.config.jpegQuality) },
                                set: { val in
                                    coordinator.config.jpegQuality = Int(val.rounded())
                                    coordinator.config.preset = .custom
                                }
                            ),
                            in: 15...95
                        )
                    }

                    Toggle("转换为黑白灰度", isOn: Binding(
                        get: { coordinator.config.grayscale },
                        set: { val in
                            coordinator.config.grayscale = val
                            coordinator.config.preset = .custom
                        }
                    ))
                }
            }

            Section("保存方式与试跑") {
                Picker("输出方式", selection: $coordinator.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: coordinator.outputMode) { _, _ in
                    coordinator.performScan()
                }

                Text(coordinator.outputMode.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if coordinator.outputMode == .inplace {
                    folderPickerRow(
                        label: "原件备份",
                        placeholder: "不备份（直接替换）",
                        url: coordinator.backupDirectoryURL,
                        onPick: {
                            coordinator.backupDirectoryURL = NativeFilePickers.pickDirectory(title: "选择原件自动备份目录")
                        },
                        onClear: { coordinator.backupDirectoryURL = nil }
                    )
                } else {
                    folderPickerRow(
                        label: "导出目录",
                        placeholder: "必选：点击指定文件夹",
                        url: coordinator.outputDirectoryURL,
                        onPick: {
                            coordinator.outputDirectoryURL = NativeFilePickers.pickDirectory(title: "选择压缩后导出目录")
                        },
                        onClear: { coordinator.outputDirectoryURL = nil }
                    )
                }

                HStack {
                    Text("试跑限制")
                    Spacer()
                    Menu(coordinator.trialLimitText.isEmpty ? "全部处理" : "仅前 \(coordinator.trialLimitText) 个") {
                        Button("全部处理") { coordinator.trialLimitText = "" }
                        Button("先试跑 5 个") { coordinator.trialLimitText = "5" }
                        Button("先试跑 10 个") { coordinator.trialLimitText = "10" }
                        Button("先试跑 25 个") { coordinator.trialLimitText = "25" }
                    }
                    .frame(width: 120)
                }

                TextField("任务备注名（可选）", text: $coordinator.customJobName)
            }

            Section("性能与安全规则") {
                Stepper(
                    "并行核心：\(coordinator.config.workers) 进程",
                    value: $coordinator.config.workers,
                    in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)
                )
                .monospacedDigit()

                HStack {
                    Text("最小节省比例")
                    Spacer()
                    TextField("1.0", value: $coordinator.config.minSavingPercent, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("%")
                        .foregroundStyle(.secondary)
                }

                Toggle("跳过历史已优化文件", isOn: $coordinator.config.skipAlreadyOptimized)
                    .onChange(of: coordinator.config.skipAlreadyOptimized) { _, _ in
                        coordinator.performScan()
                    }
                Toggle("保留原文件修改时间", isOn: $coordinator.config.preserveModificationDate)
                Toggle("清除文档元数据", isOn: $coordinator.config.stripMetadata)
            }
        }
        .formStyle(.grouped)
    }

    private func presetTile(_ preset: CompressionPreset) -> some View {
        let isSelected = coordinator.config.preset == preset
        return Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                coordinator.applyPreset(preset)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: preset.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Spacer()
                    HStack(spacing: 2.5) {
                        ForEach(1...4, id: \.self) { i in
                            Circle()
                                .fill(i <= preset.strengthLevel ? (isSelected ? Color.accentColor : Color.secondary) : Color.secondary.opacity(0.22))
                                .frame(width: 4.5, height: 4.5)
                        }
                    }
                }

                Text(preset.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(preset.estimatedSavingBadge)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isSelected ? .green : .secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.4 : 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func folderPickerRow(
        label: String,
        placeholder: String,
        url: URL?,
        onPick: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            if let url {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(url.path)
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(placeholder)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Button("选择…", action: onPick)
                .controlSize(.small)
        }
    }
}
