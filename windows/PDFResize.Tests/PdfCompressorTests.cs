using System.IO.Compression;
using System.Text;
using System.Text.Json;
using PDFResize.Core.Engine;
using PDFResize.Core.Models;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;
using SkiaSharp;
using Xunit;

namespace PDFResize.Tests;

public sealed class PdfCompressorTests : IDisposable
{
    private readonly string _tempRoot;

    public PdfCompressorTests()
    {
        _tempRoot = Path.Combine(Path.GetTempPath(), $"PDFResizeWinUITests_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempRoot);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tempRoot))
                Directory.Delete(_tempRoot, recursive: true);
        }
        catch { /* ignore */ }
    }

    [Fact]
    public void BalancedAndExtremePresets_ShrinkImageHeavyPdf_WhilePreservingVectorTextAndPageCount()
    {
        string srcJpegPdf = Path.Combine(_tempRoot, "scan_jpeg.pdf");
        string dstJpegPdf = Path.Combine(_tempRoot, "scan_jpeg_out.pdf");
        BuildSyntheticImageAndVectorPdf(srcJpegPdf, pageCount: 2, pixelSize: 1800, useFlateRgb: false);

        var balanced = CompressionConfig.ForPreset(CompressionPreset.Balanced);
        var res1 = PdfCompressor.CompressFile(srcJpegPdf, dstJpegPdf, balanced, inplace: false);

        Assert.Equal(FileProcessStatus.Done, res1.Status);
        Assert.Equal(2, res1.Pages);
        Assert.Equal(2, res1.ImagesOptimized);
        Assert.True(res1.SavedBytes > res1.OriginalSize * 0.40,
            $"Expected >40% saving, got orig={res1.OriginalSize}, new={res1.NewSize}");

        using (var verifyDoc = PdfReader.Open(dstJpegPdf, PdfDocumentOpenMode.Import))
        {
            Assert.Equal(2, verifyDoc.PageCount);
        }

        string contentText = ExtractFirstPageRawStreamText(dstJpegPdf);
        Assert.Contains("PDF Resize WinUI Vector Text 100% Preserved", contentText);

        // Also test FlateDecode uncompressed/zlib RGB bitmap XObjects
        string srcFlatePdf = Path.Combine(_tempRoot, "scan_flate.pdf");
        BuildSyntheticImageAndVectorPdf(srcFlatePdf, pageCount: 1, pixelSize: 1400, useFlateRgb: true);

        var extreme = CompressionConfig.ForPreset(CompressionPreset.Extreme);
        var res2 = PdfCompressor.CompressFile(srcFlatePdf, srcFlatePdf, extreme, inplace: true);

        Assert.Equal(FileProcessStatus.Done, res2.Status);
        Assert.Equal(1, res2.ImagesOptimized);
        Assert.True(res2.NewSize < res2.OriginalSize * 0.35,
            $"Expected >65% saving on Flate RGB scan, got orig={res2.OriginalSize}, new={res2.NewSize}");
    }

    [Fact]
    public void NeverGrowSafetyGate_SkipsPureVectorPdf_LeavingOriginalBytesIdentical()
    {
        string vectorPdf = Path.Combine(_tempRoot, "pure_vector.pdf");
        BuildPureVectorPdf(vectorPdf);
        byte[] beforeBytes = File.ReadAllBytes(vectorPdf);

        var cfg = CompressionConfig.ForPreset(CompressionPreset.Balanced);
        cfg.MinSavingPercent = 5.0;
        var res = PdfCompressor.CompressFile(vectorPdf, vectorPdf, cfg, inplace: true);

        Assert.Equal(FileProcessStatus.SkippedNoGain, res.Status);
        Assert.Equal(beforeBytes, File.ReadAllBytes(vectorPdf));
    }

    [Fact]
    public void EncryptedPdf_IsSafelySkippedWithSkippedEncryptedStatus()
    {
        string encryptedPdf = Path.Combine(_tempRoot, "locked.pdf");
        BuildPureVectorPdf(encryptedPdf, userPassword: "secret-password");

        var cfg = CompressionConfig.ForPreset(CompressionPreset.Balanced);
        var res = PdfCompressor.CompressFile(encryptedPdf, encryptedPdf, cfg, inplace: true);

        Assert.Equal(FileProcessStatus.SkippedEncrypted, res.Status);
    }

    [Fact]
    public void MultiFolderBatch_SupportsInplaceBackup_AndAdvancesCleanlyAcrossRepeatedTrialRuns()
    {
        string folderA = Path.Combine(_tempRoot, "DeptA", "Contracts");
        string folderB = Path.Combine(_tempRoot, "DeptB", "Manuals");
        string backupDir = Path.Combine(_tempRoot, "Backups");
        string dbPath = Path.Combine(_tempRoot, "test_jobs.sqlite3");

        Directory.CreateDirectory(folderA);
        Directory.CreateDirectory(folderB);

        for (int i = 1; i <= 3; i++)
        {
            BuildSyntheticImageAndVectorPdf(Path.Combine(folderA, $"a_{i}.pdf"), 1, 1500, useFlateRgb: false);
            BuildSyntheticImageAndVectorPdf(Path.Combine(folderB, $"b_{i}.pdf"), 1, 1500, useFlateRgb: false);
        }

        using var store = new JobStore(dbPath);
        using var coordinator = new BatchCoordinator(store, useSubprocessIsolation: false);
        var cfg = CompressionConfig.ForPreset(CompressionPreset.Balanced, workers: 2);

        // Trial 1: process first 3 pending PDFs across both folders
        var job1 = coordinator.CreateAndStartLocalJob(
            [Path.Combine(_tempRoot, "DeptA"), Path.Combine(_tempRoot, "DeptB")],
            OutputMode.Inplace,
            outputDir: null,
            backupDir: backupDir,
            config: cfg,
            recursive: true,
            limitFiles: 3,
            autoStart: true);

        WaitUntilCompleted(coordinator, job1.Id);
        var stats1 = store.GetJobStats(job1.Id);
        Assert.Equal(3, stats1.Done);
        Assert.True(stats1.SavedBytes > 0);
        Assert.Equal(3, Directory.GetFiles(backupDir, "*.pdf", SearchOption.AllDirectories).Length);

        // Trial 2: automatically skips first 3 fingerprinted PDFs and processes the remaining 3!
        var job2 = coordinator.CreateAndStartLocalJob(
            [Path.Combine(_tempRoot, "DeptA"), Path.Combine(_tempRoot, "DeptB")],
            OutputMode.Inplace,
            outputDir: null,
            backupDir: backupDir,
            config: cfg,
            recursive: true,
            limitFiles: 3,
            autoStart: true);

        WaitUntilCompleted(coordinator, job2.Id);
        var stats2 = store.GetJobStats(job2.Id);
        Assert.Equal(3, stats2.Done);
        Assert.Equal(6, store.GetAllFingerprints().Count);

        // Trial 3: all 6 files are now optimized -> throws actionable message mentioning "重置跳过缓存"
        var ex = Assert.Throws<InvalidOperationException>(() => coordinator.CreateAndStartLocalJob(
            [Path.Combine(_tempRoot, "DeptA"), Path.Combine(_tempRoot, "DeptB")],
            OutputMode.Inplace,
            outputDir: null,
            backupDir: backupDir,
            config: cfg,
            recursive: true,
            limitFiles: 3,
            autoStart: true));
        Assert.Contains("重置跳过缓存", ex.Message);
    }

    [Fact]
    public void WorkerCli_TryRun_ProcessesSinglePayloadCleanly()
    {
        string pdfPath = Path.Combine(_tempRoot, "worker_cli.pdf");
        BuildSyntheticImageAndVectorPdf(pdfPath, pageCount: 1, pixelSize: 1500, useFlateRgb: false);

        string reqPath = Path.Combine(_tempRoot, "req.json");
        string respPath = Path.Combine(_tempRoot, "resp.json");
        var payload = new WorkerTaskPayload(
            1,
            pdfPath,
            pdfPath,
            null,
            true,
            CompressionConfig.ForPreset(CompressionPreset.Balanced));
        File.WriteAllText(reqPath, JsonSerializer.Serialize(payload));

        bool handled = WorkerCli.TryRun(["--worker-one", reqPath, respPath]);
        Assert.True(handled);
        Assert.True(File.Exists(respPath));

        var parsed = JsonSerializer.Deserialize<SingleCompressionResult>(File.ReadAllText(respPath));
        Assert.NotNull(parsed);
        Assert.Equal(FileProcessStatus.Done, parsed!.Status);
        Assert.True(parsed.SavedBytes > 0);
    }

    private static void WaitUntilCompleted(BatchCoordinator coordinator, string jobId)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (DateTime.UtcNow < deadline)
        {
            var job = coordinator.Store.GetJob(jobId);
            if (job is not null && !coordinator.IsJobActive(jobId) &&
                job.Status is JobStatus.Completed or JobStatus.Failed or JobStatus.Cancelled)
            {
                Assert.Equal(JobStatus.Completed, job.Status);
                return;
            }
            Thread.Sleep(50);
        }
        throw new TimeoutException($"Job {jobId} did not finish within 30s");
    }

    private static void BuildPureVectorPdf(string outputPath, string? userPassword = null)
    {
        using var doc = new PdfDocument();
        var page = doc.AddPage();
        AttachHelveticaFontAndStream(doc, page, "BT /F1 14 Tf 50 750 Td (Pure Vector Contract Document) Tj ET");
        if (!string.IsNullOrEmpty(userPassword))
        {
            doc.SecuritySettings.UserPassword = userPassword;
        }
        doc.Save(outputPath);
    }

    private static void BuildSyntheticImageAndVectorPdf(string outputPath, int pageCount, int pixelSize, bool useFlateRgb)
    {
        byte[] imageStreamBytes = CreateSyntheticImageStream(pixelSize, pixelSize, useFlateRgb);

        using var doc = new PdfDocument();
        for (int p = 0; p < pageCount; p++)
        {
            var page = doc.AddPage();

            var imgDict = new PdfDictionary(doc);
            imgDict.Elements.SetName("/Type", "/XObject");
            imgDict.Elements.SetName("/Subtype", "/Image");
            imgDict.Elements.SetInteger("/Width", pixelSize);
            imgDict.Elements.SetInteger("/Height", pixelSize);
            imgDict.Elements.SetInteger("/BitsPerComponent", 8);
            imgDict.Elements.SetName("/ColorSpace", "/DeviceRGB");
            imgDict.Elements.SetName("/Filter", useFlateRgb ? "/FlateDecode" : "/DCTDecode");
            imgDict.CreateStream(imageStreamBytes);
            doc.Internals.AddObject(imgDict);

            var xObjects = new PdfDictionary(doc);
            xObjects.Elements["/Im0"] = imgDict.Reference!;

            AttachHelveticaFontAndStream(
                doc,
                page,
                $"q 480 0 0 480 56 200 cm /Im0 Do Q BT /F1 16 Tf 56 750 Td (PDF Resize WinUI Vector Text 100% Preserved - Page {p + 1}) Tj ET",
                xObjects);
        }

        doc.Save(outputPath);
    }

    private static void AttachHelveticaFontAndStream(
        PdfDocument doc,
        PdfPage page,
        string contentOperators,
        PdfDictionary? xObjects = null)
    {
        var fontDict = new PdfDictionary(doc);
        fontDict.Elements.SetName("/Type", "/Font");
        fontDict.Elements.SetName("/Subtype", "/Type1");
        fontDict.Elements.SetName("/BaseFont", "/Helvetica");
        doc.Internals.AddObject(fontDict);

        var fonts = new PdfDictionary(doc);
        fonts.Elements["/F1"] = fontDict.Reference!;

        var resources = new PdfDictionary(doc);
        resources.Elements["/Font"] = fonts;
        if (xObjects is not null)
        {
            resources.Elements["/XObject"] = xObjects;
        }
        page.Elements["/Resources"] = resources;

        var content = page.Contents.AppendContent();
        content.CreateStream(Encoding.ASCII.GetBytes(contentOperators));
    }

    private static byte[] CreateSyntheticImageStream(int width, int height, bool flateRgb)
    {
        using var bmp = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Opaque));
        using (var canvas = new SKCanvas(bmp))
        {
            using var shaderPaint = new SKPaint
            {
                Shader = SKShader.CreateLinearGradient(
                    new SKPoint(0, 0),
                    new SKPoint(width, height),
                    [new SKColor(28, 92, 185), new SKColor(235, 148, 52), new SKColor(38, 168, 120)],
                    null,
                    SKShaderTileMode.Clamp)
            };
            canvas.DrawRect(new SKRect(0, 0, width, height), shaderPaint);

            using var linePaint = new SKPaint { Color = new SKColor(255, 255, 255, 190), StrokeWidth = 3, IsAntialias = true };
            for (int i = 0; i < width; i += 24)
            {
                canvas.DrawLine(i, 0, width - i, height, linePaint);
                canvas.DrawCircle((i * 7) % width, (i * 13) % height, 18, linePaint);
            }
        }

        if (!flateRgb)
        {
            using var img = SKImage.FromBitmap(bmp);
            using var jpeg = img.Encode(SKEncodedImageFormat.Jpeg, 96);
            return jpeg.ToArray();
        }

        byte[] rgba = bmp.Bytes;
        byte[] rgb = new byte[width * height * 3];
        int s = 0, d = 0;
        int total = width * height;
        for (int i = 0; i < total; i++)
        {
            rgb[d] = rgba[s];
            rgb[d + 1] = rgba[s + 1];
            rgb[d + 2] = rgba[s + 2];
            s += 4;
            d += 3;
        }

        using var ms = new MemoryStream();
        using (var zlib = new ZLibStream(ms, CompressionLevel.Fastest, leaveOpen: true))
        {
            zlib.Write(rgb, 0, rgb.Length);
        }
        return ms.ToArray();
    }

    private static string ExtractFirstPageRawStreamText(string pdfPath)
    {
        using var doc = PdfReader.Open(pdfPath, PdfDocumentOpenMode.Modify);
        var page = doc.Pages[0];
        var sb = new StringBuilder();
        for (int i = 0; i < page.Contents.Elements.Count; i++)
        {
            var c = page.Contents.Elements.GetDictionary(i);
            if (c?.Stream?.UnfilteredValue is { } bytes)
            {
                sb.Append(Encoding.ASCII.GetString(bytes));
            }
        }
        return sb.ToString();
    }
}
