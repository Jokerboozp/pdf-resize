import Foundation

public enum DirectoryScanner {
    /// Recursively scans multiple folders and/or standalone PDF files with path deduplication,
    /// collision-free relative naming, and trial `limitFiles` support.
    public static func scan(
        sources: [URL],
        recursive: Bool = true,
        skipSmallerThanKB: Int = 0,
        fingerprints: [String: (size: Int64, mtime: TimeInterval)]? = nil,
        limitFiles: Int? = nil,
        excludeDirectories: [URL] = []
    ) throws -> ScanSummary {
        let fm = FileManager.default
        guard !sources.isEmpty else {
            throw NSError(domain: "DirectoryScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "请至少添加一个文件夹或 PDF 文件"])
        }

        let excludedPaths: Set<String> = Set(
            excludeDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )

        var normalizedSources: [(url: URL, isDir: Bool, label: String)] = []
        var seenRoots: Set<String> = []
        var labelCounts: [String: Int] = [:]

        for raw in sources {
            let std = raw.standardizedFileURL
            var isDirObj: ObjCBool = false
            guard fm.fileExists(atPath: std.path, isDirectory: &isDirObj) else {
                throw NSError(domain: "DirectoryScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "路径不存在或无访问权限: \(std.path)"])
            }
            if seenRoots.contains(std.path) { continue }
            seenRoots.insert(std.path)

            let baseName = std.lastPathComponent.isEmpty ? "Root" : std.lastPathComponent
            let key = baseName.lowercased()
            let count = (labelCounts[key] ?? 0) + 1
            labelCounts[key] = count
            let label = count == 1 ? baseName : "\(baseName)_\(count)"
            normalizedSources.append((std, isDirObj.boolValue, label))
        }

        let multiSource = normalizedSources.count > 1
        let minBytes = Int64(max(0, skipSmallerThanKB)) * 1024

        var entries: [ScannedFileEntry] = []
        var seenFiles: Set<String> = []
        var perSourceStats: [String: (count: Int, bytes: Int64, pending: Int)] = [:]

        var totalBytes: Int64 = 0
        var pendingTotal = 0
        var alreadyOptimizedCount = 0
        var tooSmallCount = 0

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        func inspectPDFFile(_ fileURL: URL, relativePath: String) -> ScannedFileEntry? {
            let name = fileURL.lastPathComponent
            let lower = name.lowercased()
            // Ignore non-PDFs, our atomic temp files, and macOS AppleDouble resource forks (._*.pdf)
            if !lower.hasSuffix(".pdf") || lower.hasSuffix(PDFCompressor.tempSuffix) || name.hasPrefix("._") {
                return nil
            }
            let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            if seenFiles.contains(resolved) { return nil }
            seenFiles.insert(resolved)

            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else {
                return nil
            }

            let size = Int64(values.fileSize ?? 0)
            let mtime = (values.contentModificationDate ?? Date()).timeIntervalSince1970

            var status: FileProcessStatus = .pending
            if let fps = fingerprints, let fp = fps[resolved] {
                if fp.size == size && abs(fp.mtime - mtime) < 2.0 {
                    status = .skippedAlreadyDone
                    alreadyOptimizedCount += 1
                }
            }
            if status == .pending && minBytes > 0 && size < minBytes {
                status = .skippedSmall
                tooSmallCount += 1
            }

            // When trial limitFiles is active, only include pending files so subsequent trial runs advance cleanly
            if let limit = limitFiles, limit > 0, status != .pending {
                return nil
            }

            return ScannedFileEntry(
                relativePath: relativePath,
                sourceURL: fileURL.standardizedFileURL,
                originalSize: size,
                modificationTime: mtime,
                initialStatus: status
            )
        }

        outer: for src in normalizedSources {
            var sCount = 0
            var sBytes: Int64 = 0
            var sPending = 0

            if !src.isDir {
                if let limit = limitFiles, pendingTotal >= limit { break outer }
                let rel = src.url.lastPathComponent
                if let item = inspectPDFFile(src.url, relativePath: rel) {
                    entries.append(item)
                    totalBytes += item.originalSize
                    sCount += 1
                    sBytes += item.originalSize
                    if item.initialStatus == .pending {
                        pendingTotal += 1
                        sPending += 1
                    }
                }
                perSourceStats[src.url.path] = (sCount, sBytes, sPending)
                continue
            }

            let rootPath = src.url.path
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsHiddenFiles]
            if !recursive {
                options.insert(.skipsSubdirectoryDescendants)
            }

            guard let enumerator = fm.enumerator(
                at: src.url,
                includingPropertiesForKeys: resourceKeys,
                options: options
            ) else {
                perSourceStats[rootPath] = (0, 0, 0)
                continue
            }

            var candidateURLs: [URL] = []
            while let nextObj = enumerator.nextObject() as? URL {
                let resolvedSub = nextObj.standardizedFileURL.resolvingSymlinksInPath().path
                if excludedPaths.contains(resolvedSub) {
                    enumerator.skipDescendants()
                    continue
                }
                if let vals = try? nextObj.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    if vals.isSymbolicLink == true { continue }
                    if vals.isDirectory == true { continue }
                }
                if nextObj.pathExtension.lowercased() == "pdf" && !nextObj.lastPathComponent.hasPrefix("._") {
                    candidateURLs.append(nextObj)
                }
            }

            candidateURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

            for fileURL in candidateURLs {
                if let limit = limitFiles, pendingTotal >= limit {
                    break
                }
                let fileStd = fileURL.standardizedFileURL.path
                var innerRel = fileStd
                if fileStd.hasPrefix(rootPath) {
                    innerRel = String(fileStd.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                if innerRel.isEmpty {
                    innerRel = fileURL.lastPathComponent
                }
                let relPath = multiSource ? "\(src.label)/\(innerRel)" : innerRel

                if let item = inspectPDFFile(fileURL, relativePath: relPath) {
                    entries.append(item)
                    totalBytes += item.originalSize
                    sCount += 1
                    sBytes += item.originalSize
                    if item.initialStatus == .pending {
                        pendingTotal += 1
                        sPending += 1
                    }
                }
            }

            perSourceStats[rootPath] = (sCount, sBytes, sPending)
            if let limit = limitFiles, pendingTotal >= limit {
                break outer
            }
        }

        let samples = Array(entries.sorted { $0.originalSize > $1.originalSize }.prefix(20))

        return ScanSummary(
            totalFiles: entries.count,
            totalBytes: totalBytes,
            pendingCount: pendingTotal,
            alreadyOptimizedCount: alreadyOptimizedCount,
            tooSmallCount: tooSmallCount,
            perSourceStats: perSourceStats,
            largestSamples: samples,
            entries: entries
        )
    }
}
