import XCTest
import PDFKit
import AppKit
import CoreGraphics
@testable import PDFResizeCore

final class PDFCompressorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFResizeSwiftTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Synthetic Test PDF Generators

    private func makePhotoAndTextPDF(at url: URL, pages: Int = 2, imageWidth: Int = 1800, imageHeight: Int = 1400) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create CGPDFContext")
            return
        }

        for pageIdx in 0..<pages {
            ctx.beginPDFPage(nil)

            // Draw selectable vector text via CoreText / NSAttributedString
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            let text = "PDF Resize Swift Native Test - Page \(pageIdx + 1)" as NSString
            text.draw(
                at: NSPoint(x: 48, y: 780),
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 18),
                    .foregroundColor: NSColor.black
                ]
            )
            NSGraphicsContext.restoreGraphicsState()

            // Generate high-entropy RGB bitmap image (simulating high-DPI scanned photo)
            let bytesPerRow = imageWidth * 4
            var pixels = [UInt8](repeating: 255, count: imageHeight * bytesPerRow)
            var seed: UInt64 = UInt64(1234567 + pageIdx * 9973)
            for y in 0..<imageHeight {
                for x in 0..<imageWidth {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let noise = UInt8((seed >> 33) & 0x3F)
                    let offset = y * bytesPerRow + x * 4
                    pixels[offset + 0] = UInt8((x * 255 / imageWidth) & 0xC0) &+ noise
                    pixels[offset + 1] = UInt8((y * 255 / imageHeight) & 0xC0) &+ (noise >> 1)
                    pixels[offset + 2] = UInt8(((x + y) * 127 / imageWidth) & 0xC0) &+ noise
                    pixels[offset + 3] = 255
                }
            }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let provider = CGDataProvider(data: Data(pixels) as CFData),
               let cgImg = CGImage(
                   width: imageWidth,
                   height: imageHeight,
                   bitsPerComponent: 8,
                   bitsPerPixel: 32,
                   bytesPerRow: bytesPerRow,
                   space: colorSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider,
                   decode: nil,
                   shouldInterpolate: true,
                   intent: .defaultIntent
               ) {
                ctx.draw(cgImg, in: CGRect(x: 40, y: 70, width: 515, height: 680))
            }

            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func makeEncryptedPDF(at url: URL) throws {
        let plainURL = tempDir.appendingPathComponent("_plain_lock.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        let consumer = CGDataConsumer(url: plainURL as CFURL)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = PDFDocument(url: plainURL)!
        let ok = doc.write(to: url, withOptions: [
            .userPasswordOption: "secret123",
            .ownerPasswordOption: "owner123"
        ])
        XCTAssertTrue(ok)
        try? FileManager.default.removeItem(at: plainURL)
    }

    // MARK: - Tests

    func testBalancedAndExtremeCompressionPreservesVectorText() throws {
        let src = tempDir.appendingPathComponent("heavy_photo.pdf")
        try makePhotoAndTextPDF(at: src, pages: 2)
        let origSize = try FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int64
        XCTAssertGreaterThan(origSize, 500_000)

        let outBalanced = tempDir.appendingPathComponent("balanced.pdf")
        let resBal = PDFCompressor.compressFile(
            sourceURL: src,
            destinationURL: outBalanced,
            config: .forPreset(.balanced),
            inplace: false
        )
        XCTAssertEqual(resBal.status, .done)
        XCTAssertEqual(resBal.pages, 2)
        XCTAssertLessThan(resBal.newSize, Int64(Double(origSize) * 0.55))

        // Verify vector text remains crisp and selectable
        let checkDoc = try XCTUnwrap(PDFDocument(url: outBalanced))
        XCTAssertEqual(checkDoc.pageCount, 2)
        XCTAssertTrue(checkDoc.page(at: 0)?.string?.contains("PDF Resize Swift Native Test - Page 1") == true)
        XCTAssertTrue(checkDoc.page(at: 1)?.string?.contains("PDF Resize Swift Native Test - Page 2") == true)

        let outExtreme = tempDir.appendingPathComponent("extreme.pdf")
        let resExt = PDFCompressor.compressFile(
            sourceURL: src,
            destinationURL: outExtreme,
            config: .forPreset(.extreme),
            inplace: false
        )
        XCTAssertEqual(resExt.status, .done)
        XCTAssertLessThan(resExt.newSize, resBal.newSize)
    }

    func testEncryptedSkipAndInplaceAtomicBackup() throws {
        let locked = tempDir.appendingPathComponent("locked.pdf")
        try makeEncryptedPDF(at: locked)
        let beforeData = try Data(contentsOf: locked)

        let encRes = PDFCompressor.compressFile(
            sourceURL: locked,
            destinationURL: locked,
            config: .forPreset(.balanced),
            inplace: true
        )
        XCTAssertEqual(encRes.status, .skippedEncrypted)
        XCTAssertEqual(try Data(contentsOf: locked), beforeData)

        // In-place atomic replacement with backup preservation
        let inplaceTarget = tempDir.appendingPathComponent("inplace_doc.pdf")
        try makePhotoAndTextPDF(at: inplaceTarget, pages: 1)
        let origData = try Data(contentsOf: inplaceTarget)
        let backupURL = tempDir.appendingPathComponent("backups/inplace_doc.pdf")

        let res = PDFCompressor.compressFile(
            sourceURL: inplaceTarget,
            destinationURL: inplaceTarget,
            config: .forPreset(.balanced),
            inplace: true,
            backupURL: backupURL
        )
        XCTAssertEqual(res.status, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), origData)
        let finalSize = try FileManager.default.attributesOfItem(atPath: inplaceTarget.path)[.size] as! Int64
        XCTAssertEqual(finalSize, res.newSize)
        XCTAssertLessThan(finalSize, Int64(origData.count))
    }

    func testMultiFolderDeduplicationAndTrialLimitAdvancement() throws {
        let dirA = tempDir.appendingPathComponent("Disk1/Docs", isDirectory: true)
        let dirASub = dirA.appendingPathComponent("2026", isDirectory: true)
        let dirB = tempDir.appendingPathComponent("Disk2/Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: dirASub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let f1 = dirA.appendingPathComponent("a.pdf")
        let f2 = dirASub.appendingPathComponent("b.pdf")
        let f3 = dirB.appendingPathComponent("a.pdf")
        try makePhotoAndTextPDF(at: f1, pages: 1, imageWidth: 800, imageHeight: 600)
        try makePhotoAndTextPDF(at: f2, pages: 1, imageWidth: 800, imageHeight: 600)
        try makePhotoAndTextPDF(at: f3, pages: 1, imageWidth: 800, imageHeight: 600)

        // Overlapping dirA + dirASub must deduplicate to 3 unique files
        let scanAll = try DirectoryScanner.scan(sources: [dirA, dirASub, dirB], recursive: true)
        XCTAssertEqual(scanAll.totalFiles, 3)

        // SQLite JobStore + fingerprint trial advancement
        let store = try JobStore(dbURL: tempDir.appendingPathComponent("test.sqlite3"))
        let f1Resolved = f1.standardizedFileURL.resolvingSymlinksInPath().path
        let f1Attrs = try FileManager.default.attributesOfItem(atPath: f1.path)
        store.recordFingerprint(
            filePath: f1Resolved,
            fileSize: (f1Attrs[.size] as! NSNumber).int64Value,
            mtime: (f1Attrs[.modificationDate] as! Date).timeIntervalSince1970,
            preset: "balanced"
        )

        let trialScan = try DirectoryScanner.scan(
            sources: [dirA, dirB],
            recursive: true,
            fingerprints: store.getAllFingerprints(),
            limitFiles: 2
        )
        XCTAssertEqual(trialScan.totalFiles, 2)
        XCTAssertEqual(trialScan.pendingCount, 2)
        XCTAssertFalse(trialScan.entries.contains(where: { $0.sourceURL.standardizedFileURL.path == f1.standardizedFileURL.path }))
    }
}
