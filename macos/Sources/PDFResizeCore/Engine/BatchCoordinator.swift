import Foundation
import UserNotifications

// MARK: - Child Worker Batch IPC Payload (for isolated 25-file process recycling)

public struct WorkerTaskItem: Codable, Sendable {
    public let fileID: Int64
    public let sourcePath: String
    public let destinationPath: String
    public let backupPath: String?
    public let inplace: Bool
}

public struct WorkerBatchPayload: Codable, Sendable {
    public let config: CompressionConfig
    public let items: [WorkerTaskItem]
}

public enum WorkerCLI {
    /// Invoked when the app binary is launched with `--worker-one <request.json> <response.json>`
    public static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.count >= 4, arguments[1] == "--worker-one" else {
            return false
        }
        let reqURL = URL(fileURLWithPath: arguments[2])
        let respURL = URL(fileURLWithPath: arguments[3])

        do {
            let data = try Data(contentsOf: reqURL)
            let payload = try JSONDecoder().decode(WorkerBatchPayload.self, from: data)
            var results: [Int64: SingleCompressionResult] = [:]
            for item in payload.items {
                let res = PDFCompressor.compressFile(
                    sourceURL: URL(fileURLWithPath: item.sourcePath),
                    destinationURL: URL(fileURLWithPath: item.destinationPath),
                    config: payload.config,
                    inplace: item.inplace,
                    backupURL: item.backupPath.map { URL(fileURLWithPath: $0) }
                )
                results[item.fileID] = res
            }
            let outData = try JSONEncoder().encode(results)
            try outData.write(to: respURL, options: .atomic)
            return true
        } catch {
            fputs("Worker error: \(error)\n", stderr)
            exit(2)
        }
    }
}

// MARK: - Reactive MainActor Batch Coordinator

public enum AppNavigationSection: String, CaseIterable, Identifiable {
    case workbench = "workbench"
    case compare = "compare"
    case jobs = "jobs"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .workbench: return "批量压缩"
        case .compare: return "画质对比"
        case .jobs: return "任务队列"
        }
    }

    public var subtitle: String {
        switch self {
        case .workbench: return "多目录直连 · 强度与保存"
        case .compare: return "卷帘逐像素对比 · 同步缩放"
        case .jobs: return "实时吞吐 · 断点续传"
        }
    }

    public var symbolName: String {
        switch self {
        case .workbench: return "square.stack.3d.down.right.fill"
        case .compare: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .jobs: return "waveform.path.ecg"
        }
    }
}

private final class JobControlFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _cancelled = false

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _paused
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func requestPause() {
        lock.lock(); _paused = true; lock.unlock()
    }
    func requestCancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

@MainActor
public final class BatchCoordinator: ObservableObject {
    @Published public var selectedSection: AppNavigationSection = .workbench
    @Published public var sources: [SourceItem] = []
    @Published public var recursiveScan: Bool = true
    @Published public var config: CompressionConfig = .forPreset(.balanced)
    @Published public var outputMode: OutputMode = .inplace
    @Published public var outputDirectoryURL: URL?
    @Published public var backupDirectoryURL: URL?
    @Published public var trialLimitText: String = ""
    @Published public var customJobName: String = ""

    @Published public var lastScanSummary: ScanSummary?
    @Published public var isScanning: Bool = false

    @Published public var jobs: [JobRecord] = []
    @Published public var selectedJobID: String?
    @Published public var selectedJobFiles: [JobFileRow] = []
    @Published public var fileStatusFilter: String = "all"
    @Published public var fileSearchQuery: String = ""

    @Published public var bytesPerSecond: Double = 0
    @Published public var etaSeconds: Int?
    @Published public var activeFileNames: [String] = []

    // Compare tab state
    @Published public var compareSourceURL: URL?
    @Published public var compareCompressedURL: URL?
    @Published public var compareResult: SingleCompressionResult?
    @Published public var isComparing: Bool = false

    @Published public var alertTitle: String = ""
    @Published public var alertMessage: String = ""
    @Published public var isShowingAlert: Bool = false
    @Published public var sendNotificationOnComplete: Bool = true

    public let store: JobStore
    private var controlFlags: [String: JobControlFlags] = [:]
    private var speedSamples: [(ts: TimeInterval, bytes: Int64)] = []
    private let useSubprocessIsolation: Bool

    public init(store: JobStore? = nil, useSubprocessIsolation: Bool? = nil) {
        let resolvedStore = (try? store ?? JobStore()) ?? (try! JobStore(dbURL: FileManager.default.temporaryDirectory.appendingPathComponent("fallback_jobs.sqlite3")))
        self.store = resolvedStore
        self.store.recoverInterruptedJobs()

        if let explicit = useSubprocessIsolation {
            self.useSubprocessIsolation = explicit
        } else {
            let execName = Bundle.main.executableURL?.lastPathComponent ?? ""
            self.useSubprocessIsolation = (execName == "PDFResize")
        }

        refreshJobs()
    }

    public var runningJobsCount: Int {
        jobs.filter { $0.status == .running }.count
    }

    public var lifetimeSavedBytes: Int64 {
        jobs.reduce(0) { $0 + $1.stats.savedBytes }
    }

    public var lifetimeOptimizedCount: Int {
        jobs.reduce(0) { $0 + $1.stats.done }
    }

    public var selectedJob: JobRecord? {
        guard let id = selectedJobID else { return jobs.first }
        return jobs.first(where: { $0.id == id }) ?? jobs.first
    }

    // MARK: - Source Management & Scanning

    public func addSourceURLs(_ urls: [URL]) {
        let fm = FileManager.default
        var added = 0
        for raw in urls {
            let std = raw.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: std.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue && std.pathExtension.lowercased() != "pdf" { continue }
            if !sources.contains(where: { $0.id == std.path }) {
                sources.append(SourceItem(url: std, isDirectory: isDir.boolValue))
                added += 1
            }
        }
        if added > 0 {
            performScan()
        }
    }

    public func removeSource(id: String) {
        sources.removeAll { $0.id == id }
        if sources.isEmpty {
            lastScanSummary = nil
        } else {
            performScan()
        }
    }

    public func clearSources() {
        sources.removeAll()
        lastScanSummary = nil
    }

    public func applyPreset(_ preset: CompressionPreset) {
        config = CompressionConfig.forPreset(preset, currentWorkers: config.workers)
    }

    public func performScan() {
        guard !sources.isEmpty else {
            lastScanSummary = nil
            return
        }
        isScanning = true
        let urls = sources.map(\.url)
        let rec = recursiveScan
        let skipKB = config.skipSmallerThanKB
        let skipDone = config.skipAlreadyOptimized && outputMode == .inplace
        let storeRef = self.store
        var excludes: [URL] = []
        if let out = outputDirectoryURL { excludes.append(out) }
        if let bkp = backupDirectoryURL { excludes.append(bkp) }

        Task.detached(priority: .userInitiated) {
            let fps = skipDone ? storeRef.getAllFingerprints() : nil
            let result = Result {
                try DirectoryScanner.scan(
                    sources: urls,
                    recursive: rec,
                    skipSmallerThanKB: skipKB,
                    fingerprints: fps,
                    limitFiles: nil,
                    excludeDirectories: excludes
                )
            }
            await MainActor.run {
                self.isScanning = false
                switch result {
                case .success(let summary):
                    self.lastScanSummary = summary
                    for idx in self.sources.indices {
                        let p = self.sources[idx].url.path
                        if let st = summary.perSourceStats[p] {
                            self.sources[idx].scannedCount = st.count
                            self.sources[idx].scannedBytes = st.bytes
                            self.sources[idx].pendingCount = st.pending
                        }
                    }
                    if self.compareSourceURL == nil, let firstSample = summary.largestSamples.first {
                        self.compareSourceURL = firstSample.sourceURL
                    }
                case .failure(let err):
                    self.showError("扫描失败", message: err.localizedDescription)
                }
            }
        }
    }

    // MARK: - Single File Quality Preview

    public func runQualityComparison(for url: URL? = nil) {
        guard let targetURL = url ?? compareSourceURL else {
            showError("请选择 PDF 文件", message: "请先从访达选择一个 PDF 文件以预览压缩效果。")
            return
        }
        compareSourceURL = targetURL
        isComparing = true
        let cfg = config

        Task.detached(priority: .userInitiated) {
            do {
                let (outURL, res) = try PDFCompressor.generatePreviewCopy(sourceURL: targetURL, config: cfg)
                await MainActor.run {
                    self.compareCompressedURL = outURL
                    self.compareResult = res
                    self.isComparing = false
                }
            } catch {
                await MainActor.run {
                    self.isComparing = false
                    self.showError("试压对比失败", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Create & Start Batch Job

    public func createAndStartJob() {
        guard !sources.isEmpty else {
            showError("尚未添加文件", message: "请先拖入或选择至少一个包含 PDF 的文件夹。")
            return
        }
        if outputMode == .outputDirectory && outputDirectoryURL == nil {
            showError("未指定输出文件夹", message: "选择「另存到新文件夹」时，请先指定保存位置。")
            return
        }

        let urls = sources.map(\.url)
        let rec = recursiveScan
        let cfg = config
        let mode = outputMode
        let outURL = outputDirectoryURL
        let bkpURL = backupDirectoryURL
        let limitVal = Int(trialLimitText.trimmingCharacters(in: .whitespaces))
        let limitFiles = (limitVal != nil && limitVal! > 0) ? limitVal : nil
        let customName = customJobName.trimmingCharacters(in: .whitespaces)
        let storeRef = self.store

        var excludes: [URL] = []
        if let outURL { excludes.append(outURL) }
        if let bkpURL { excludes.append(bkpURL) }

        Task.detached(priority: .userInitiated) {
            do {
                let fps = (cfg.skipAlreadyOptimized && mode == .inplace) ? storeRef.getAllFingerprints() : nil
                let scan = try DirectoryScanner.scan(
                    sources: urls,
                    recursive: rec,
                    skipSmallerThanKB: cfg.skipSmallerThanKB,
                    fingerprints: fps,
                    limitFiles: limitFiles,
                    excludeDirectories: excludes
                )

                if scan.totalFiles == 0 {
                    let msg: String
                    if scan.alreadyOptimizedCount > 0 {
                        msg = "所选目录中的 \(scan.alreadyOptimizedCount) 个 PDF 均已在之前优化过。如需重新试跑或再次压缩，请在设置中点击「重置跳过缓存」或关闭「跳过历史已优化文件」。"
                    } else if scan.tooSmallCount > 0 {
                        msg = "所选目录中的 \(scan.tooSmallCount) 个 PDF 均小于最小体积跳过阈值。"
                    } else {
                        msg = "所选路径中未找到任何 PDF 文件。"
                    }
                    throw NSError(domain: "BatchCoordinator", code: 10, userInfo: [NSLocalizedDescriptionKey: msg])
                }

                let jobID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
                let defaultName: String
                if !customName.isEmpty {
                    defaultName = customName
                } else if urls.count == 1 {
                    defaultName = "\(urls[0].lastPathComponent) (\(scan.totalFiles) 个 PDF)"
                } else {
                    defaultName = "\(urls.count) 个位置合并 (\(scan.totalFiles) 个 PDF)"
                }

                let mappedFiles: [(entry: ScannedFileEntry, dstPath: String, backupPath: String?)] = scan.entries.map { entry in
                    let dstPath: String
                    if mode == .inplace {
                        dstPath = entry.sourceURL.path
                    } else {
                        dstPath = outURL!.appendingPathComponent(entry.relativePath).path
                    }
                    let bkpPath: String?
                    if mode == .inplace, let bkpURL {
                        bkpPath = bkpURL.appendingPathComponent(entry.relativePath).path
                    } else {
                        bkpPath = nil
                    }
                    return (entry, dstPath, bkpPath)
                }

                let summaryPaths = urls.map(\.path).joined(separator: " ; ")
                let created = try storeRef.createJob(
                    id: jobID,
                    name: defaultName,
                    sourceSummary: summaryPaths,
                    outputMode: mode,
                    outputDir: outURL?.path,
                    backupDir: bkpURL?.path,
                    config: cfg,
                    files: mappedFiles
                )

                await MainActor.run {
                    self.refreshJobs()
                    self.selectedJobID = created.id
                    self.selectedSection = .jobs
                    self.reloadSelectedJobFiles()
                    self.startJob(jobID: created.id)
                }
            } catch {
                await MainActor.run {
                    self.showError("无法启动压缩任务", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Job Execution & Lifecycle

    public func startJob(jobID: String) {
        guard controlFlags[jobID] == nil else { return }
        guard let job = store.getJob(id: jobID) else { return }

        let flags = JobControlFlags()
        controlFlags[jobID] = flags
        store.resetJobProcessingToPending(jobID: jobID)
        store.updateJobStatus(jobID, status: .running, setStarted: true)
        speedSamples.removeAll()
        refreshJobs()
        reloadSelectedJobFiles()

        let storeRef = self.store
        let cfg = job.config
        let inplace = (job.outputMode == .inplace)
        let useSubproc = self.useSubprocessIsolation
        let workers = max(1, min(cfg.workers, ProcessInfo.processInfo.activeProcessorCount))

        Task.detached(priority: .utility) { [weak self] in
            let initialStats = storeRef.getJobStats(jobID: jobID)
            if initialStats.pending == 0 {
                storeRef.updateJobStatus(jobID, status: .completed, setFinished: true)
                await MainActor.run {
                    self?.controlFlags.removeValue(forKey: jobID)
                    self?.refreshJobs()
                    self?.reloadSelectedJobFiles()
                }
                return
            }

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask {
                        await Self.workerLoop(
                            jobID: jobID,
                            config: cfg,
                            inplace: inplace,
                            store: storeRef,
                            flags: flags,
                            useSubprocess: useSubproc,
                            coordinator: self
                        )
                    }
                }
            }

            let finalStatus: JobStatus
            if flags.isCancelled {
                storeRef.resetJobProcessingToPending(jobID: jobID)
                storeRef.updateJobStatus(jobID, status: .cancelled, setFinished: true)
                finalStatus = .cancelled
            } else if flags.isPaused {
                storeRef.resetJobProcessingToPending(jobID: jobID)
                storeRef.updateJobStatus(jobID, status: .paused)
                finalStatus = .paused
            } else {
                storeRef.updateJobStatus(jobID, status: .completed, setFinished: true)
                finalStatus = .completed
            }

            let finishedJob = storeRef.getJob(id: jobID)
            await MainActor.run {
                guard let self else { return }
                self.controlFlags.removeValue(forKey: jobID)
                self.activeFileNames.removeAll()
                self.bytesPerSecond = 0
                self.etaSeconds = nil
                self.refreshJobs()
                self.reloadSelectedJobFiles()
                if finalStatus == .completed, let finishedJob, self.sendNotificationOnComplete {
                    self.postCompletionNotification(job: finishedJob)
                }
            }
        }
    }

    private static func workerLoop(
        jobID: String,
        config: CompressionConfig,
        inplace: Bool,
        store: JobStore,
        flags: JobControlFlags,
        useSubprocess: Bool,
        coordinator: BatchCoordinator?
    ) async {
        // Claim small batches of up to 4 files per worker iteration; recycle subprocesses cleanly
        while !flags.isPaused && !flags.isCancelled {
            let claimed = store.claimPendingFiles(jobID: jobID, limit: 3)
            if claimed.isEmpty { break }

            let names = claimed.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent }
            await MainActor.run {
                for n in names where !(coordinator?.activeFileNames.contains(n) ?? true) {
                    coordinator?.activeFileNames.append(n)
                }
            }

            for row in claimed {
                if flags.isPaused || flags.isCancelled {
                    break
                }
                let res: SingleCompressionResult
                if useSubprocess {
                    res = executeInIsolatedSubprocess(row: row, config: config, inplace: inplace)
                } else {
                    res = PDFCompressor.compressFile(
                        sourceURL: URL(fileURLWithPath: row.sourcePath),
                        destinationURL: URL(fileURLWithPath: row.destinationPath),
                        config: config,
                        inplace: inplace,
                        backupURL: row.backupPath.map { URL(fileURLWithPath: $0) }
                    )
                }

                store.updateFileResult(fileID: row.id, result: res)
                if inplace && (res.status == .done || res.status == .skippedNoGain) {
                    let mtime = res.newModificationTime ?? row.modificationTime
                    store.recordFingerprint(
                        filePath: row.sourcePath,
                        fileSize: res.newSize,
                        mtime: mtime,
                        preset: config.preset.rawValue
                    )
                }

                let finishedName = URL(fileURLWithPath: row.relativePath).lastPathComponent
                await MainActor.run {
                    coordinator?.recordProgress(processedBytes: row.originalSize, finishedFileName: finishedName, jobID: jobID)
                }
            }
        }
    }

    /// Runs a single PDF compression in a short-lived child process of our own executable
    /// so C/CoreGraphics heap pages are 100% reclaimed by macOS across 60GB / 3000+ PDFs
    /// and a malformed PDF crash never affects the UI process.
    private static func executeInIsolatedSubprocess(
        row: JobFileRow,
        config: CompressionConfig,
        inplace: Bool
    ) -> SingleCompressionResult {
        guard let execURL = Bundle.main.executableURL else {
            return PDFCompressor.compressFile(
                sourceURL: URL(fileURLWithPath: row.sourcePath),
                destinationURL: URL(fileURLWithPath: row.destinationPath),
                config: config,
                inplace: inplace,
                backupURL: row.backupPath.map { URL(fileURLWithPath: $0) }
            )
        }

        let tmp = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let reqURL = tmp.appendingPathComponent("pdfresize_req_\(token).json")
        let respURL = tmp.appendingPathComponent("pdfresize_resp_\(token).json")
        defer {
            try? FileManager.default.removeItem(at: reqURL)
            try? FileManager.default.removeItem(at: respURL)
        }

        let payload = WorkerBatchPayload(
            config: config,
            items: [
                WorkerTaskItem(
                    fileID: row.id,
                    sourcePath: row.sourcePath,
                    destinationPath: row.destinationPath,
                    backupPath: row.backupPath,
                    inplace: inplace
                )
            ]
        )

        do {
            try JSONEncoder().encode(payload).write(to: reqURL)
            let proc = Process()
            proc.executableURL = execURL
            proc.arguments = ["--worker-one", reqURL.path, respURL.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus == 0,
               let data = try? Data(contentsOf: respURL),
               let dict = try? JSONDecoder().decode([Int64: SingleCompressionResult].self, from: data),
               let res = dict[row.id] {
                return res
            }
            return SingleCompressionResult(
                status: .failed,
                originalSize: row.originalSize,
                newSize: row.originalSize,
                savedBytes: 0,
                durationMs: 0,
                errorMessage: "子工作进程异常退出 (code \(proc.terminationStatus))"
            )
        } catch {
            return SingleCompressionResult(
                status: .failed,
                originalSize: row.originalSize,
                newSize: row.originalSize,
                savedBytes: 0,
                durationMs: 0,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func recordProgress(processedBytes: Int64, finishedFileName: String, jobID: String) {
        activeFileNames.removeAll { $0 == finishedFileName }
        let now = Date().timeIntervalSince1970
        speedSamples.append((now, processedBytes))
        let cutoff = now - 25.0
        speedSamples.removeAll { $0.ts < cutoff }

        let windowBytes = speedSamples.reduce(Int64(0)) { $0 + $1.bytes }
        let earliest = speedSamples.first?.ts ?? now
        let elapsed = max(0.8, now - earliest)
        bytesPerSecond = windowBytes > 0 ? Double(windowBytes) / elapsed : 0

        refreshJobs()
        if let active = jobs.first(where: { $0.id == jobID }) {
            let remaining = max(Int64(0), active.stats.totalOriginalBytes - active.stats.processedOriginalBytes)
            etaSeconds = bytesPerSecond > 1024 ? Int(Double(remaining) / bytesPerSecond) : nil
        }
        if selectedJobID == jobID {
            reloadSelectedJobFiles()
        }
    }

    // MARK: - User Actions on Jobs

    public func pauseJob(_ jobID: String) {
        controlFlags[jobID]?.requestPause()
    }

    public func cancelJob(_ jobID: String) {
        if let flags = controlFlags[jobID] {
            flags.requestCancel()
        } else {
            store.updateJobStatus(jobID, status: .cancelled, setFinished: true)
            refreshJobs()
        }
    }

    public func retryFailed(_ jobID: String) {
        let count = store.retryFailedFiles(jobID: jobID)
        if count > 0 {
            startJob(jobID: jobID)
        }
    }

    public func deleteJob(_ jobID: String) {
        guard controlFlags[jobID] == nil else { return }
        store.deleteJob(id: jobID)
        if selectedJobID == jobID {
            selectedJobID = nil
        }
        refreshJobs()
        reloadSelectedJobFiles()
    }

    public func refreshJobs() {
        jobs = store.listJobs()
        if selectedJobID == nil, let first = jobs.first {
            selectedJobID = first.id
        }
    }

    public func reloadSelectedJobFiles() {
        guard let jid = selectedJob?.id else {
            selectedJobFiles = []
            return
        }
        selectedJobFiles = store.listJobFiles(
            jobID: jid,
            statusFilter: fileStatusFilter,
            search: fileSearchQuery
        )
    }

    public func clearOptimizationCache() -> Int {
        let removed = store.clearFingerprints()
        if !sources.isEmpty {
            performScan()
        }
        return removed
    }

    public func showError(_ title: String, message: String) {
        alertTitle = title
        alertMessage = message
        isShowingAlert = true
    }

    private func postCompletionNotification(job: JobRecord) {
        // UNUserNotificationCenter requires a valid .app bundle identifier
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "PDF 批量压缩完成"
            content.body = "\(job.name) 已完成，共释放 \(ByteFormat.string(job.stats.savedBytes)) 空间（-\(String(format: "%.1f", job.stats.savingPercent))%）。"
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req)
        }
    }
}
