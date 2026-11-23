import SwiftUI
import PDFKit

// MARK: - Native PDFKit View Wrapper

public struct NativePDFPageView: NSViewRepresentable {
    public let url: URL?
    public let pageIndex: Int
    public let zoomScale: CGFloat

    public init(url: URL?, pageIndex: Int, zoomScale: CGFloat) {
        self.url = url
        self.pageIndex = pageIndex
        self.zoomScale = zoomScale
    }

    public func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor = .clear
        pdfView.autoScales = true
        return pdfView
    }

    public func updateNSView(_ pdfView: PDFView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            if let url {
                pdfView.document = PDFDocument(url: url)
            } else {
                pdfView.document = nil
            }
        }

        if let doc = pdfView.document, doc.pageCount > 0 {
            let clamped = max(0, min(pageIndex, doc.pageCount - 1))
            if let targetPage = doc.page(at: clamped), pdfView.currentPage !== targetPage {
                pdfView.go(to: targetPage)
            }
            if zoomScale <= 0 {
                pdfView.autoScales = true
            } else {
                pdfView.autoScales = false
                let fit = pdfView.scaleFactorForSizeToFit
                pdfView.scaleFactor = max(0.25, fit * zoomScale)
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator {
        var loadedURL: URL?
    }
}

// MARK: - Quality Comparison Workspace

public enum CompareLayoutMode: String, CaseIterable, Identifiable {
    case splitCurtain = "卷帘对比"
    case sideBySide = "并排双栏"

    public var id: String { rawValue }
}

public struct QualityCompareView: View {
    @ObservedObject var coordinator: BatchCoordinator
    @State private var layoutMode: CompareLayoutMode = .splitCurtain
    @State private var splitRatio: CGFloat = 0.5
    @State private var currentPageIndex: Int = 0
    @State private var zoomMultiplier: CGFloat = 1.0

    public init(coordinator: BatchCoordinator) {
        self.coordinator = coordinator
    }

    private var totalPages: Int {
        max(1, coordinator.compareResult?.pages ?? 1)
    }

    public var body: some View {
        VStack(spacing: 0) {
            topFloatingControlBar
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ZStack {
                if coordinator.isComparing {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在使用原生 Quartz 引擎实时试压…")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .liquidGlassCard(cornerRadius: 20)
                } else if let src = coordinator.compareSourceURL, let comp = coordinator.compareCompressedURL {
                    comparisonCanvas(origURL: src, compURL: comp)
                } else {
                    emptyComparePlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    private var topFloatingControlBar: some View {
        HStack(spacing: 12) {
            // Preset quick-switcher pills
            HStack(spacing: 4) {
                ForEach(CompressionPreset.selectablePresets) { preset in
                    let active = coordinator.config.preset == preset
                    Button {
                        coordinator.applyPreset(preset)
                        if coordinator.compareSourceURL != nil {
                            coordinator.runQualityComparison()
                        }
                    } label: {
                        Text(preset.title)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(active ? Color.accentColor : Color.clear, in: Capsule())
                            .foregroundStyle(active ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .liquidGlassCapsule()

            if let res = coordinator.compareResult {
                HStack(spacing: 8) {
                    Text(ByteFormat.string(res.originalSize))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(res.newSize))
                        .fontWeight(.semibold)

                    let pct = res.originalSize > 0 ? (Double(max(0, res.savedBytes)) / Double(res.originalSize)) * 100.0 : 0
                    Text(String(format: "-%.1f%%", pct))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
                .font(.system(size: 12.5))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
            }

            Spacer()

            // Page & Zoom controls
            if coordinator.compareCompressedURL != nil {
                HStack(spacing: 6) {
                    Button {
                        currentPageIndex = max(0, currentPageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .disabled(currentPageIndex <= 0)

                    Text("第 \(currentPageIndex + 1) / \(totalPages) 页")
                        .font(.system(size: 12))
                        .monospacedDigit()

                    Button {
                        currentPageIndex = min(totalPages - 1, currentPageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(currentPageIndex >= totalPages - 1)

                    Divider().frame(height: 14)

                    Button {
                        zoomMultiplier = max(0.75, zoomMultiplier - 0.25)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.plain)

                    Button("适应") {
                        zoomMultiplier = 1.0
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))

                    Button {
                        zoomMultiplier = min(4.0, zoomMultiplier + 0.25)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
            }

            Picker("", selection: $layoutMode) {
                ForEach(CompareLayoutMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 156)
        }
    }

    @ViewBuilder
    private func comparisonCanvas(origURL: URL, compURL: URL) -> some View {
        switch layoutMode {
        case .splitCurtain:
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let splitX = width * splitRatio

                ZStack(alignment: .leading) {
                    // Bottom layer: Compressed PDF
                    NativePDFPageView(url: compURL, pageIndex: currentPageIndex, zoomScale: zoomMultiplier)
                        .frame(width: geo.size.width, height: geo.size.height)

                    // Top layer: Original PDF masked to left side of curtain
                    NativePDFPageView(url: origURL, pageIndex: currentPageIndex, zoomScale: zoomMultiplier)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: splitX, height: geo.size.height)
                        }

                    // Corner floating labels
                    VStack {
                        HStack {
                            Text("原文件 · 矢量渲染")
                                .font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .liquidGlassCapsule()
                            Spacer()
                            Text("压缩后 (\(coordinator.config.preset.title))")
                                .font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .liquidGlassCapsule()
                        }
                        .padding(14)
                        Spacer()
                    }

                    // Interactive Liquid Glass Curtain Handle
                    ZStack {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                            .shadow(color: .black.opacity(0.35), radius: 4)

                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 36, height: 36)
                            .overlay {
                                Image(systemName: "arrow.left.and.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .overlay {
                                Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                    }
                    .frame(width: 40, height: geo.size.height)
                    .contentShape(Rectangle())
                    .position(x: splitX, y: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                splitRatio = min(0.96, max(0.04, value.location.x / width))
                            }
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .liquidGlassCard(cornerRadius: 18)
            }

        case .sideBySide:
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text("原始 PDF")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.vertical, 7)
                    Divider()
                    NativePDFPageView(url: origURL, pageIndex: currentPageIndex, zoomScale: zoomMultiplier)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .liquidGlassCard(cornerRadius: 16)

                VStack(spacing: 0) {
                    Text("压缩后 PDF")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.vertical, 7)
                    Divider()
                    NativePDFPageView(url: compURL, pageIndex: currentPageIndex, zoomScale: zoomMultiplier)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .liquidGlassCard(cornerRadius: 16)
            }
        }
    }

    private var emptyComparePlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.lefthalf.inset.filled.arrow.left")
                .font(.system(size: 42))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            Text("在大批量处理 60GB 文档前，先肉眼确认画质")
                .font(.system(size: 17, weight: .semibold, design: .rounded))

            Text("支持拖入任意 PDF，使用苹果原生 PDFKit 矢量渲染逐像素卷帘对比，原文件绝不会被修改。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Button {
                if let url = NativeFilePickers.pickSinglePDF() {
                    currentPageIndex = 0
                    coordinator.runQualityComparison(for: url)
                }
            } label: {
                Label("选择单个 PDF 试压…", systemImage: "doc.badge.plus")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .adaptiveGlassButton(prominent: true)
        }
        .padding(38)
        .liquidGlassCard(cornerRadius: 22)
    }
}
