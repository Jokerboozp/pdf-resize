import Foundation
import PDFKit
import Quartz
import CoreGraphics

public enum PDFCompressor {
    public static let tempSuffix = ".pdfresize.tmp"

    /// Compress a single PDF file using macOS native QuartzFilter + PDFKit/CoreGraphics
    /// while keeping vector text, links, and outlines intact.
    public static func compressFile(
        sourceURL: URL,
        destinationURL: URL,
        config: CompressionConfig,
        inplace: Bool,
        backupURL: URL? = nil
    ) -> SingleCompressionResult {
        let startTime = DispatchTime.now()
        func elapsedMs() -> Int {
            let nanos = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
            return Int(nanos / 1_000_000)
        }

        return autoreleasepool {
            let fm = FileManager.default
            let src = sourceURL.standardizedFileURL
            let dst = destinationURL.standardizedFileURL

            guard fm.fileExists(atPath: src.path) else {
                return SingleCompressionResult(
                    status: .failed,
                    originalSize: 0,
                    newSize: 0,
                    savedBytes: 0,
                    durationMs: elapsedMs(),
                    errorMessage: "源文件不存在"
                )
            }

            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try fm.attributesOfItem(atPath: src.path)
            } catch {
                return SingleCompressionResult(
                    status: .failed,
                    originalSize: 0,
                    newSize: 0,
                    savedBytes: 0,
                    durationMs: elapsedMs(),
                    errorMessage: "无法读取文件属性: \(error.localizedDescription)"
                )
            }

            let origSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let origModDate = (attrs[.modificationDate] as? Date) ?? Date()

            if origSize == 0 {
                return SingleCompressionResult(
                    status: .skippedEmpty,
                    originalSize: 0,
                    newSize: 0,
                    savedBytes: 0,
                    durationMs: elapsedMs(),
                    errorMessage: "空文件"
                )
            }

            if config.skipSmallerThanKB > 0 && origSize < Int64(config.skipSmallerThanKB) * 1024 {
                if !inplace && src.path != dst.path {
                    try? copyPreservingParent(from: src, to: dst)
                }
                return SingleCompressionResult(
                    status: .skippedSmall,
                    originalSize: origSize,
                    newSize: origSize,
                    savedBytes: 0,
                    durationMs: elapsedMs()
                )
            }

            guard let pdfDoc = PDFDocument(url: src) else {
                return SingleCompressionResult(
                    status: .failed,
                    originalSize: origSize,
                    newSize: origSize,
                    savedBytes: 0,
                    durationMs: elapsedMs(),
                    errorMessage: "无法解析 PDF（文件可能已损坏）"
                )
            }

            if pdfDoc.isEncrypted && pdfDoc.isLocked {
                if !pdfDoc.unlock(withPassword: "") {
                    if !inplace && src.path != dst.path {
                        try? copyPreservingParent(from: src, to: dst)
                    }
                    return SingleCompressionResult(
                        status: .skippedEncrypted,
                        originalSize: origSize,
                        newSize: origSize,
                        savedBytes: 0,
                        durationMs: elapsedMs(),
                        errorMessage: "PDF 受密码保护"
                    )
                }
            }

            let origPageCount = pdfDoc.pageCount
            if origPageCount == 0 {
                return SingleCompressionResult(
                    status: .skippedEmpty,
                    originalSize: origSize,
                    newSize: origSize,
                    savedBytes: 0,
                    durationMs: elapsedMs(),
                    errorMessage: "PDF 页数为 0"
                )
            }

            let parentDir = dst.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                return SingleCompressionResult(
                    status: .failed,
                    originalSize: origSize,
                    newSize: origSize,
                    savedBytes: 0,
                    durationMs: elapsedMs(),
                    pages: origPageCount,
                    errorMessage: "无法创建目标目录: \(error.localizedDescription)"
                )
            }

            let pid = ProcessInfo.processInfo.processIdentifier
            let token = UUID().uuidString.prefix(8)
            let tmpPDFURL = parentDir.appendingPathComponent(".\(dst.lastPathComponent).\(pid).\(token)\(tempSuffix)")
            var tmpFilterURL: URL?

            defer {
                try? fm.removeItem(at: tmpPDFURL)
                if let fURL = tmpFilterURL {
                    try? fm.removeItem(at: fURL)
                }
            }

            do {
                if config.stripMetadata {
                    pdfDoc.documentAttributes = [:]
                }

                var wroteOK = false
                if config.compressImages && config.preset != .lossless {
                    let filterURL = try buildTemporaryQuartzFilter(for: config)
                    tmpFilterURL = filterURL

                    if let qFilter = QuartzFilter(url: filterURL) {
                        // Run CGPDFContext + QuartzFilter (aggressive image stream re-encoding) and
                        // PDFDocument.write(withOptions:) (preserves outlines/links), keeping whichever
                        // valid output achieves smaller size.
                        let altTmpURL = parentDir.appendingPathComponent(".\(dst.lastPathComponent).\(pid).\(token).alt\(tempSuffix)")
                        defer { try? fm.removeItem(at: altTmpURL) }

                        let cgOK = writeFilteredCGPDF(sourceURL: src, outputURL: tmpPDFURL, filter: qFilter, stripMetadata: config.stripMetadata)
                        let opts: [PDFDocumentWriteOption: Any] = [
                            PDFDocumentWriteOption(rawValue: "QuartzFilter"): qFilter
                        ]
                        let pdfKitOK = pdfDoc.write(to: altTmpURL, withOptions: opts)

                        let cgValid = cgOK && verifyPDFIntegrity(url: tmpPDFURL, expectedPages: origPageCount)
                        let kitValid = pdfKitOK && verifyPDFIntegrity(url: altTmpURL, expectedPages: origPageCount)

                        if cgValid && kitValid {
                            let cgSize = ((try? fm.attributesOfItem(atPath: tmpPDFURL.path)[.size] as? NSNumber)?.int64Value) ?? Int64.max
                            let kitSize = ((try? fm.attributesOfItem(atPath: altTmpURL.path)[.size] as? NSNumber)?.int64Value) ?? Int64.max
                            if kitSize <= cgSize {
                                _ = try? fm.replaceItemAt(tmpPDFURL, withItemAt: altTmpURL)
                            }
                            wroteOK = true
                        } else if kitValid {
                            if fm.fileExists(atPath: tmpPDFURL.path) {
                                _ = try? fm.replaceItemAt(tmpPDFURL, withItemAt: altTmpURL)
                            } else {
                                try? fm.moveItem(at: altTmpURL, to: tmpPDFURL)
                            }
                            wroteOK = true
                        } else if cgValid {
                            wroteOK = true
                        }
                    }
                }

                if !wroteOK {
                    // Lossless rewrite / stream cleanup
                    wroteOK = pdfDoc.write(to: tmpPDFURL)
                }

                guard wroteOK, fm.fileExists(atPath: tmpPDFURL.path) else {
                    throw NSError(domain: "PDFCompressor", code: 2, userInfo: [NSLocalizedDescriptionKey: "写入临时压缩文件失败"])
                }

                guard verifyPDFIntegrity(url: tmpPDFURL, expectedPages: origPageCount) else {
                    throw NSError(domain: "PDFCompressor", code: 3, userInfo: [NSLocalizedDescriptionKey: "压缩后文件页数或完整性校验未通过"])
                }

                let newAttrs = try fm.attributesOfItem(atPath: tmpPDFURL.path)
                let newSize = (newAttrs[.size] as? NSNumber)?.int64Value ?? origSize
                let savedBytes = origSize - newSize
                let savedPct = origSize > 0 ? (Double(savedBytes) / Double(origSize)) * 100.0 : 0.0

                // Safety gate: never replace if file grew or savings are below minimum threshold
                if savedBytes <= 0 || savedPct < config.minSavingPercent {
                    if !inplace && src.path != dst.path {
                        try copyPreservingParent(from: src, to: dst)
                    }
                    return SingleCompressionResult(
                        status: .skippedNoGain,
                        originalSize: origSize,
                        newSize: origSize,
                        savedBytes: 0,
                        durationMs: elapsedMs(),
                        pages: origPageCount,
                        newModificationTime: origModDate.timeIntervalSince1970
                    )
                }

                // Optional backup before in-place overwrite (never overwrite an existing original backup)
                if inplace, let bkp = backupURL?.standardizedFileURL {
                    if !fm.fileExists(atPath: bkp.path) {
                        try fm.createDirectory(at: bkp.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: src, to: bkp)
                    }
                }

                if config.preserveModificationDate {
                    try? fm.setAttributes([.modificationDate: origModDate], ofItemAtPath: tmpPDFURL.path)
                }

                // Atomic same-volume replacement
                if fm.fileExists(atPath: dst.path) {
                    _ = try fm.replaceItemAt(dst, withItemAt: tmpPDFURL)
                } else {
                    try fm.moveItem(at: tmpPDFURL, to: dst)
                }

                let finalAttrs = try? fm.attributesOfItem(atPath: dst.path)
                let finalMtime = ((finalAttrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970

                return SingleCompressionResult(
                    status: .done,
                    originalSize: origSize,
                    newSize: newSize,
                    savedBytes: savedBytes,
                    durationMs: elapsedMs(),
                    pages: origPageCount,
                    newModificationTime: finalMtime
                )
            } catch {
                return SingleCompressionResult(
                    status: .failed,
                    originalSize: origSize,
                    newSize: origSize,
                    savedBytes: 0,
                    durationMs: elapsedMs(),
                    pages: origPageCount,
                    errorMessage: String(error.localizedDescription.prefix(300))
                )
            }
        }
    }

    // MARK: - Preview Helper (Non-destructive)

    public static func generatePreviewCopy(sourceURL: URL, config: CompressionConfig) throws -> (outputURL: URL, result: SingleCompressionResult) {
        let previewDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFResizePreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        // Cleanup preview files older than 20 minutes
        if let items = try? FileManager.default.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-1200)
            for url in items {
                if let mdate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   mdate < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        let outURL = previewDir.appendingPathComponent("preview_\(UUID().uuidString.prefix(10)).pdf")
        var previewCfg = config
        previewCfg.minSavingPercent = 0.0
        let res = compressFile(sourceURL: sourceURL, destinationURL: outURL, config: previewCfg, inplace: false)
        let effectiveURL = FileManager.default.fileExists(atPath: outURL.path) ? outURL : sourceURL
        return (effectiveURL, res)
    }

    // MARK: - QuartzFilter Synthesis & CoreGraphics PDF Pipeline

    private static func buildTemporaryQuartzFilter(for config: CompressionConfig) throws -> URL {
        // Map user JPEG quality (15...95) to QuartzFilter's [-1.0, +1.0] range (0.0 == ~50% medium)
        let mappedQuality = max(-0.95, min(0.95, (Double(config.jpegQuality) / 50.0) - 1.0))
        let maxPixels = config.downsampleImages ? max(128, Int((Double(config.targetDPI) * 11.7).rounded())) : 0
        let targetDPI = config.downsampleImages ? max(50, config.targetDPI) : 0

        // Start from system Reduce File Size.qfilter dictionary if available for exact OS schema compatibility
        var rootDict: [String: Any] = [
            "Domains": [
                "Applications": true,
                "Printing": true
            ],
            "FilterType": 1,
            "Name": "PDFResizeDynamicFilter"
        ]

        let sysReduceURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        if let data = try? Data(contentsOf: sysReduceURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            rootDict = plist
            rootDict["Name"] = "PDFResizeDynamicFilter"
        }

        var filterData = (rootDict["FilterData"] as? [String: Any]) ?? [:]
        var colorSettings = (filterData["ColorSettings"] as? [String: Any]) ?? [:]

        // Optional grayscale profile merge from system Gray Tone.qfilter
        if config.grayscale {
            let grayURL = URL(fileURLWithPath: "/System/Library/Filters/Gray Tone.qfilter")
            if let gData = try? Data(contentsOf: grayURL),
               let gPlist = try? PropertyListSerialization.propertyList(from: gData, options: [], format: nil) as? [String: Any],
               let gFilterData = gPlist["FilterData"] as? [String: Any],
               let gColorSettings = gFilterData["ColorSettings"] as? [String: Any] {
                for (k, v) in gColorSettings where k != "ImageSettings" {
                    colorSettings[k] = v
                }
            }
        }

        var imageSettings = (colorSettings["ImageSettings"] as? [String: Any]) ?? [:]
        imageSettings["ImageCompression"] = "ImageJPEGCompress"
        imageSettings["Compression Quality"] = mappedQuality

        var scaleSettings = (imageSettings["ImageScaleSettings"] as? [String: Any]) ?? [:]
        // Preserve OS-native type for ImageScaleInterpolate if present
        if scaleSettings["ImageScaleInterpolate"] is Bool {
            scaleSettings["ImageScaleInterpolate"] = true
        } else {
            scaleSettings["ImageScaleInterpolate"] = 3
        }
        scaleSettings["ImageScaleFactor"] = 0.0
        scaleSettings["ImageResolution"] = targetDPI
        scaleSettings["ImageSizeMax"] = maxPixels
        scaleSettings["ImageSizeMin"] = config.downsampleImages ? 64 : 0

        imageSettings["ImageScaleSettings"] = scaleSettings
        colorSettings["ImageSettings"] = imageSettings
        filterData["ColorSettings"] = colorSettings
        rootDict["FilterData"] = filterData

        let plistData = try PropertyListSerialization.data(fromPropertyList: rootDict, format: .xml, options: 0)
        let tmpDir = FileManager.default.temporaryDirectory
        let filterURL = tmpDir.appendingPathComponent("pdfresize_\(ProcessInfo.processInfo.processIdentifier)_\(UUID().uuidString.prefix(8)).qfilter")
        try plistData.write(to: filterURL, options: .atomic)
        return filterURL
    }

    private static func writeFilteredCGPDF(
        sourceURL: URL,
        outputURL: URL,
        filter: QuartzFilter,
        stripMetadata: Bool
    ) -> Bool {
        guard let cgDoc = CGPDFDocument(sourceURL as CFURL) else { return false }
        let pageCount = cgDoc.numberOfPages
        guard pageCount > 0 else { return false }

        var auxiliaryInfo: [CFString: Any] = [:]
        if !stripMetadata, let info = cgDoc.info {
            if let title = getPDFString(info, key: "Title") {
                auxiliaryInfo[kCGPDFContextTitle] = title
            }
            if let author = getPDFString(info, key: "Author") {
                auxiliaryInfo[kCGPDFContextAuthor] = author
            }
            if let subject = getPDFString(info, key: "Subject") {
                auxiliaryInfo[kCGPDFContextSubject] = subject
            }
        }

        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let pdfContext = CGContext(consumer: consumer, mediaBox: nil, auxiliaryInfo.isEmpty ? nil : (auxiliaryInfo as CFDictionary)) else {
            return false
        }

        guard filter.apply(to: pdfContext) else {
            return false
        }

        for pageIndex in 1...pageCount {
            autoreleasepool {
                guard let page = cgDoc.page(at: pageIndex) else { return }
                var mediaBox = page.getBoxRect(.mediaBox)
                if mediaBox.isEmpty {
                    mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
                }

                var pageDict: [CFString: Any] = [
                    kCGPDFContextMediaBox: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
                ]
                var cropBox = page.getBoxRect(.cropBox)
                if !cropBox.isEmpty && cropBox != mediaBox {
                    pageDict[kCGPDFContextCropBox] = NSData(bytes: &cropBox, length: MemoryLayout<CGRect>.size)
                }

                pdfContext.beginPDFPage(pageDict as CFDictionary)
                let rotation = page.rotationAngle
                if rotation != 0 {
                    // Preserve original page rotation cleanly via drawing transform
                    let transform = page.getDrawingTransform(.mediaBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true)
                    pdfContext.saveGState()
                    pdfContext.concatenate(transform)
                    pdfContext.drawPDFPage(page)
                    pdfContext.restoreGState()
                } else {
                    pdfContext.drawPDFPage(page)
                }
                pdfContext.endPDFPage()
            }
        }

        pdfContext.closePDF()
        return true
    }

    private static func getPDFString(_ dict: CGPDFDictionaryRef, key: String) -> String? {
        var strRef: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dict, key, &strRef),
              let s = strRef,
              let cfStr = CGPDFStringCopyTextString(s) else {
            return nil
        }
        return cfStr as String
    }

    private static func verifyPDFIntegrity(url: URL, expectedPages: Int) -> Bool {
        guard let checkDoc = PDFDocument(url: url),
              checkDoc.pageCount == expectedPages else {
            return false
        }
        if expectedPages > 0 {
            guard checkDoc.page(at: 0) != nil else { return false }
            if expectedPages > 1 {
                guard checkDoc.page(at: expectedPages - 1) != nil else { return false }
            }
        }
        return true
    }

    private static func copyPreservingParent(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }
}
