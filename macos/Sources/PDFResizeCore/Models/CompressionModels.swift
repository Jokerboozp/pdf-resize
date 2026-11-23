import Foundation

public enum CompressionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case lossless
    case light
    case balanced
    case extreme
    case custom

    public var id: String { rawValue }

    public static var selectablePresets: [CompressionPreset] {
        [.lossless, .light, .balanced, .extreme]
    }

    public var title: String {
        switch self {
        case .lossless: return "无损清理"
        case .light: return "高清轻压"
        case .balanced: return "均衡推荐"
        case .extreme: return "极致瘦身"
        case .custom: return "自定义参数"
        }
    }

    public var subtitle: String {
        switch self {
        case .lossless: return "保留原始画质，清理冗余流与元数据"
        case .light: return "200 DPI · 质量 82%，适合打印与高清阅读"
        case .balanced: return "150 DPI · 质量 70%，画质与体积黄金平衡"
        case .extreme: return "100 DPI · 质量 50%，扫描件大幅缩减空间"
        case .custom: return "按你设定的分辨率与质量精细控制"
        }
    }

    public var estimatedSavingBadge: String {
        switch self {
        case .lossless: return "约省 5%–20%"
        case .light: return "约省 25%–50%"
        case .balanced: return "约省 45%–75%"
        case .extreme: return "约省 65%–88%"
        case .custom: return "自定义压缩率"
        }
    }

    public var symbolName: String {
        switch self {
        case .lossless: return "sparkles"
        case .light: return "printer.fill"
        case .balanced: return "dial.medium.fill"
        case .extreme: return "bolt.fill"
        case .custom: return "slider.horizontal.3"
        }
    }

    public var strengthLevel: Int {
        switch self {
        case .lossless: return 1
        case .light: return 2
        case .balanced: return 3
        case .extreme: return 4
        case .custom: return 3
        }
    }
}

public enum OutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case inplace
    case outputDirectory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inplace: return "原地直接优化"
        case .outputDirectory: return "另存到新文件夹"
        }
    }

    public var subtitle: String {
        switch self {
        case .inplace:
            return "同盘原子写入并校验页数，仅当确实变小时才替换原文件"
        case .outputDirectory:
            return "原文件保留不动，在目标文件夹完整保持子目录层级"
        }
    }
}

public struct CompressionConfig: Codable, Equatable, Sendable {
    public var preset: CompressionPreset
    public var compressImages: Bool
    public var downsampleImages: Bool
    public var targetDPI: Int
    public var jpegQuality: Int
    public var grayscale: Bool
    public var stripMetadata: Bool
    public var minSavingPercent: Double
    public var skipSmallerThanKB: Int
    public var skipAlreadyOptimized: Bool
    public var preserveModificationDate: Bool
    public var workers: Int

    public static func recommendedWorkers() -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(1, min(cores > 4 ? cores - 2 : cores, 8))
    }

    public init(
        preset: CompressionPreset = .balanced,
        compressImages: Bool = true,
        downsampleImages: Bool = true,
        targetDPI: Int = 150,
        jpegQuality: Int = 70,
        grayscale: Bool = false,
        stripMetadata: Bool = false,
        minSavingPercent: Double = 1.0,
        skipSmallerThanKB: Int = 0,
        skipAlreadyOptimized: Bool = true,
        preserveModificationDate: Bool = true,
        workers: Int = CompressionConfig.recommendedWorkers()
    ) {
        self.preset = preset
        self.compressImages = compressImages
        self.downsampleImages = downsampleImages
        self.targetDPI = targetDPI
        self.jpegQuality = jpegQuality
        self.grayscale = grayscale
        self.stripMetadata = stripMetadata
        self.minSavingPercent = minSavingPercent
        self.skipSmallerThanKB = skipSmallerThanKB
        self.skipAlreadyOptimized = skipAlreadyOptimized
        self.preserveModificationDate = preserveModificationDate
        self.workers = workers
    }

    public static func forPreset(_ preset: CompressionPreset, currentWorkers: Int? = nil) -> CompressionConfig {
        let w = currentWorkers ?? recommendedWorkers()
        switch preset {
        case .lossless:
            return CompressionConfig(
                preset: .lossless,
                compressImages: false,
                downsampleImages: false,
                targetDPI: 300,
                jpegQuality: 92,
                grayscale: false,
                stripMetadata: false,
                minSavingPercent: 0.5,
                workers: w
            )
        case .light:
            return CompressionConfig(
                preset: .light,
                compressImages: true,
                downsampleImages: true,
                targetDPI: 200,
                jpegQuality: 82,
                grayscale: false,
                stripMetadata: false,
                minSavingPercent: 1.0,
                workers: w
            )
        case .balanced, .custom:
            return CompressionConfig(
                preset: preset,
                compressImages: true,
                downsampleImages: true,
                targetDPI: 150,
                jpegQuality: 70,
                grayscale: false,
                stripMetadata: false,
                minSavingPercent: 1.0,
                workers: w
            )
        case .extreme:
            return CompressionConfig(
                preset: .extreme,
                compressImages: true,
                downsampleImages: true,
                targetDPI: 100,
                jpegQuality: 50,
                grayscale: false,
                stripMetadata: true,
                minSavingPercent: 1.0,
                workers: w
            )
        }
    }
}

public enum FileProcessStatus: String, Codable, Sendable, CaseIterable {
    case pending = "pending"
    case processing = "processing"
    case done = "done"
    case skippedNoGain = "skipped_no_gain"
    case skippedSmall = "skipped_small"
    case skippedEncrypted = "skipped_encrypted"
    case skippedEmpty = "skipped_empty"
    case skippedAlreadyDone = "skipped_already_done"
    case failed = "failed"

    public var isSkipped: Bool {
        rawValue.hasPrefix("skipped_")
    }

    public var isFinished: Bool {
        self != .pending && self != .processing
    }

    public var displayTitle: String {
        switch self {
        case .pending: return "等待中"
        case .processing: return "处理中"
        case .done: return "已优化"
        case .skippedNoGain: return "已是最优"
        case .skippedSmall: return "体积过小"
        case .skippedEncrypted: return "密码保护"
        case .skippedEmpty: return "空文档"
        case .skippedAlreadyDone: return "历史已优化"
        case .failed: return "失败"
        }
    }
}

public enum JobStatus: String, Codable, Sendable {
    case created
    case running
    case paused
    case completed
    case cancelled
    case failed

    public var displayTitle: String {
        switch self {
        case .created: return "准备就绪"
        case .running: return "正在优化"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "异常中断"
        }
    }

    public var isActive: Bool {
        self == .running || self == .created
    }
}

public struct SourceItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let isDirectory: Bool
    public var scannedCount: Int?
    public var scannedBytes: Int64?
    public var pendingCount: Int?

    public init(url: URL, isDirectory: Bool, scannedCount: Int? = nil, scannedBytes: Int64? = nil, pendingCount: Int? = nil) {
        let std = url.standardizedFileURL
        self.id = std.path
        self.url = std
        self.isDirectory = isDirectory
        self.scannedCount = scannedCount
        self.scannedBytes = scannedBytes
        self.pendingCount = pendingCount
    }

    public var displayName: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

public struct ScannedFileEntry: Sendable {
    public let relativePath: String
    public let sourceURL: URL
    public let originalSize: Int64
    public let modificationTime: TimeInterval
    public let initialStatus: FileProcessStatus

    public init(
        relativePath: String,
        sourceURL: URL,
        originalSize: Int64,
        modificationTime: TimeInterval,
        initialStatus: FileProcessStatus
    ) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.originalSize = originalSize
        self.modificationTime = modificationTime
        self.initialStatus = initialStatus
    }
}

public struct ScanSummary: Sendable {
    public let totalFiles: Int
    public let totalBytes: Int64
    public let pendingCount: Int
    public let alreadyOptimizedCount: Int
    public let tooSmallCount: Int
    public let perSourceStats: [String: (count: Int, bytes: Int64, pending: Int)]
    public let largestSamples: [ScannedFileEntry]
    public let entries: [ScannedFileEntry]
}

public struct SingleCompressionResult: Codable, Sendable {
    public let status: FileProcessStatus
    public let originalSize: Int64
    public let newSize: Int64
    public let savedBytes: Int64
    public let durationMs: Int
    public let pages: Int
    public let errorMessage: String?
    public let newModificationTime: TimeInterval?

    public init(
        status: FileProcessStatus,
        originalSize: Int64,
        newSize: Int64,
        savedBytes: Int64,
        durationMs: Int,
        pages: Int = 0,
        errorMessage: String? = nil,
        newModificationTime: TimeInterval? = nil
    ) {
        self.status = status
        self.originalSize = originalSize
        self.newSize = newSize
        self.savedBytes = savedBytes
        self.durationMs = durationMs
        self.pages = pages
        self.errorMessage = errorMessage
        self.newModificationTime = newModificationTime
    }
}

public struct JobStats: Equatable, Sendable {
    public var totalFiles: Int = 0
    public var pending: Int = 0
    public var processing: Int = 0
    public var done: Int = 0
    public var skipped: Int = 0
    public var failed: Int = 0
    public var totalOriginalBytes: Int64 = 0
    public var processedOriginalBytes: Int64 = 0
    public var processedNewBytes: Int64 = 0
    public var savedBytes: Int64 = 0

    public init() {}

    public var completedFiles: Int {
        done + skipped + failed
    }

    public var progressByBytes: Double {
        guard totalOriginalBytes > 0 else {
            return totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0
        }
        return min(1.0, max(0.0, Double(processedOriginalBytes) / Double(totalOriginalBytes)))
    }

    public var savingPercent: Double {
        guard processedOriginalBytes > 0 else { return 0 }
        return (Double(savedBytes) / Double(processedOriginalBytes)) * 100.0
    }
}

public struct JobRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var sourceSummary: String
    public var outputMode: OutputMode
    public var outputDir: String?
    public var backupDir: String?
    public var config: CompressionConfig
    public var status: JobStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var stats: JobStats
}

public struct JobFileRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let jobID: String
    public let relativePath: String
    public let sourcePath: String
    public let destinationPath: String
    public let backupPath: String?
    public let originalSize: Int64
    public let modificationTime: TimeInterval
    public var newSize: Int64?
    public var savedBytes: Int64
    public var status: FileProcessStatus
    public var errorMessage: String?
    public var durationMs: Int?
    public var pages: Int

    public var savingPercent: Double {
        guard originalSize > 0, savedBytes > 0 else { return 0 }
        return (Double(savedBytes) / Double(originalSize)) * 100.0
    }

    public var effectiveURL: URL {
        let dst = URL(fileURLWithPath: destinationPath)
        if FileManager.default.fileExists(atPath: dst.path) {
            return dst
        }
        return URL(fileURLWithPath: sourcePath)
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func etaString(_ seconds: Int?) -> String {
        guard let sec = seconds, sec >= 0 else { return "计算中…" }
        if sec < 60 { return "\(sec) 秒" }
        let m = sec / 60
        let s = sec % 60
        if m < 60 { return "\(m) 分 \(s) 秒" }
        return "\(m / 60) 小时 \(m % 60) 分"
    }
}
