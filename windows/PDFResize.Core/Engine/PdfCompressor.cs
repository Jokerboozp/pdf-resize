using System.Diagnostics;
using PDFResize.Core.Models;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;
using PdfSharp.Pdf.Security;
using SkiaSharp;

namespace PDFResize.Core.Engine;

public static class PdfCompressor
{
    public const string TempSuffix = ".pdfresize.tmp";

    /// <summary>
    /// Compresses a PDF in-place or to a destination path while preserving 100% of vector text,
    /// fonts, bookmarks, hyperlinks, and annotations.
    /// </summary>
    public static SingleCompressionResult CompressFile(
        string sourcePath,
        string destinationPath,
        CompressionConfig config,
        bool inplace,
        string? backupPath = null)
    {
        var sw = Stopwatch.StartNew();
        int ElapsedMs() => (int)sw.ElapsedMilliseconds;

        var srcInfo = new FileInfo(Path.GetFullPath(sourcePath));
        if (!srcInfo.Exists)
        {
            return new SingleCompressionResult
            {
                Status = FileProcessStatus.Failed,
                DurationMs = ElapsedMs(),
                ErrorMessage = "源文件不存在"
            };
        }

        long origSize = srcInfo.Length;
        DateTime origWriteUtc = srcInfo.LastWriteTimeUtc;
        double origMtimeUnix = new DateTimeOffset(origWriteUtc, TimeSpan.Zero).ToUnixTimeMilliseconds() / 1000.0;

        if (origSize == 0)
        {
            return new SingleCompressionResult
            {
                Status = FileProcessStatus.SkippedEmpty,
                DurationMs = ElapsedMs(),
                ErrorMessage = "空文件"
            };
        }

        string fullDst = Path.GetFullPath(destinationPath);

        if (config.SkipSmallerThanKb > 0 && origSize < (long)config.SkipSmallerThanKb * 1024L)
        {
            if (!inplace && !PathsEqual(srcInfo.FullName, fullDst))
            {
                CopyEnsuringDirectory(srcInfo.FullName, fullDst);
            }
            return new SingleCompressionResult
            {
                Status = FileProcessStatus.SkippedSmall,
                OriginalSize = origSize,
                NewSize = origSize,
                DurationMs = ElapsedMs()
            };
        }

        string dstDir = Path.GetDirectoryName(fullDst) ?? Directory.GetCurrentDirectory();
        Directory.CreateDirectory(dstDir);

        string token = $"{Environment.ProcessId}.{Guid.NewGuid():N}"[..16];
        string tmpPath = Path.Combine(dstDir, $".{Path.GetFileName(fullDst)}.{token}{TempSuffix}");

        int origPages = 0;
        int imagesOptimized = 0;

        try
        {
            PdfDocument doc;
            try
            {
                doc = PdfReader.Open(srcInfo.FullName, PdfDocumentOpenMode.Modify);
            }
            catch (PdfReaderException pex) when (
                pex.Message.Contains("password", StringComparison.OrdinalIgnoreCase) ||
                pex.Message.Contains("encrypt", StringComparison.OrdinalIgnoreCase) ||
                pex.Message.Contains("security", StringComparison.OrdinalIgnoreCase))
            {
                if (!inplace && !PathsEqual(srcInfo.FullName, fullDst))
                {
                    CopyEnsuringDirectory(srcInfo.FullName, fullDst);
                }
                return new SingleCompressionResult
                {
                    Status = FileProcessStatus.SkippedEncrypted,
                    OriginalSize = origSize,
                    NewSize = origSize,
                    DurationMs = ElapsedMs(),
                    ErrorMessage = "PDF 受密码保护"
                };
            }

            using (doc)
            {
                origPages = doc.PageCount;
                if (origPages == 0)
                {
                    return new SingleCompressionResult
                    {
                        Status = FileProcessStatus.SkippedEmpty,
                        OriginalSize = origSize,
                        NewSize = origSize,
                        DurationMs = ElapsedMs(),
                        ErrorMessage = "PDF 页数为 0"
                    };
                }

                if (config.CompressImages && config.Preset != CompressionPreset.Lossless)
                {
                    imagesOptimized = OptimizeEmbeddedImages(doc, config);
                }

                if (config.StripMetadata)
                {
                    doc.Info.Title = string.Empty;
                    doc.Info.Author = string.Empty;
                    doc.Info.Subject = string.Empty;
                    doc.Info.Keywords = string.Empty;
                    doc.Info.Creator = string.Empty;
                    foreach (PdfObject obj in doc.Internals.GetAllObjects())
                    {
                        if (obj is PdfDictionary cat && cat.Elements.GetName("/Type") == "/Catalog")
                        {
                            cat.Elements.Remove("/Metadata");
                        }
                    }
                }

                doc.Options.CompressContentStreams = true;
                doc.Options.FlateEncodeMode = PdfFlateEncodeMode.BestCompression;
                doc.Options.NoCompression = false;
                doc.Options.EnableCcittCompressionForBilevelImages = true;

                doc.Save(tmpPath);
            }

            if (!VerifyIntegrity(tmpPath, origPages))
            {
                throw new InvalidOperationException("压缩输出 PDF 页数或结构完整性校验未通过");
            }

            long newSize = new FileInfo(tmpPath).Length;
            long savedBytes = origSize - newSize;
            double savedPct = origSize > 0 ? (double)savedBytes / origSize * 100.0 : 0.0;

            // Safety gate: never overwrite if file grew or failed minimum saving threshold
            if (savedBytes <= 0 || savedPct < config.MinSavingPercent)
            {
                if (!inplace && !PathsEqual(srcInfo.FullName, fullDst))
                {
                    CopyEnsuringDirectory(srcInfo.FullName, fullDst);
                }
                return new SingleCompressionResult
                {
                    Status = FileProcessStatus.SkippedNoGain,
                    OriginalSize = origSize,
                    NewSize = origSize,
                    SavedBytes = 0,
                    DurationMs = ElapsedMs(),
                    Pages = origPages,
                    ImagesOptimized = imagesOptimized,
                    NewModificationTimeUnix = origMtimeUnix
                };
            }

            if (inplace && !string.IsNullOrWhiteSpace(backupPath))
            {
                string fullBackup = Path.GetFullPath(backupPath);
                if (!File.Exists(fullBackup))
                {
                    CopyEnsuringDirectory(srcInfo.FullName, fullBackup);
                }
            }

            if (config.PreserveModificationDate)
            {
                try { File.SetLastWriteTimeUtc(tmpPath, origWriteUtc); } catch { /* ignore */ }
            }

            // Atomic same-volume replacement (MoveFileExW MOVEFILE_REPLACE_EXISTING)
            File.Move(tmpPath, fullDst, overwrite: true);

            DateTime finalUtc = File.GetLastWriteTimeUtc(fullDst);
            double finalUnix = new DateTimeOffset(finalUtc, TimeSpan.Zero).ToUnixTimeMilliseconds() / 1000.0;

            return new SingleCompressionResult
            {
                Status = FileProcessStatus.Done,
                OriginalSize = origSize,
                NewSize = newSize,
                SavedBytes = savedBytes,
                DurationMs = ElapsedMs(),
                Pages = origPages,
                ImagesOptimized = imagesOptimized,
                NewModificationTimeUnix = finalUnix
            };
        }
        catch (Exception ex)
        {
            string msg = ex.Message;
            if (msg.Contains("password", StringComparison.OrdinalIgnoreCase) ||
                msg.Contains("security", StringComparison.OrdinalIgnoreCase))
            {
                return new SingleCompressionResult
                {
                    Status = FileProcessStatus.SkippedEncrypted,
                    OriginalSize = origSize,
                    NewSize = origSize,
                    DurationMs = ElapsedMs(),
                    ErrorMessage = "PDF 受密码保护"
                };
            }

            return new SingleCompressionResult
            {
                Status = FileProcessStatus.Failed,
                OriginalSize = origSize,
                NewSize = origSize,
                DurationMs = ElapsedMs(),
                Pages = origPages,
                ImagesOptimized = imagesOptimized,
                ErrorMessage = msg.Length > 300 ? msg[..300] : msg
            };
        }
        finally
        {
            try
            {
                if (File.Exists(tmpPath))
                    File.Delete(tmpPath);
            }
            catch { /* ignore */ }
        }
    }

    public static (string OutputPath, SingleCompressionResult Result) GeneratePreviewCopy(string sourcePath, CompressionConfig config)
    {
        string previewDir = Path.Combine(Path.GetTempPath(), "PDFResizeWinUIPreviews");
        Directory.CreateDirectory(previewDir);

        foreach (var old in new DirectoryInfo(previewDir).EnumerateFiles("*.pdf"))
        {
            if (DateTime.UtcNow - old.LastWriteTimeUtc > TimeSpan.FromMinutes(20))
            {
                try { old.Delete(); } catch { /* ignore */ }
            }
        }

        string outPath = Path.Combine(previewDir, $"preview_{Guid.NewGuid():N}.pdf");
        var previewCfg = config.Clone();
        previewCfg.MinSavingPercent = 0.0;
        var res = CompressFile(sourcePath, outPath, previewCfg, inplace: false);
        string effective = File.Exists(outPath) ? outPath : sourcePath;
        return (effective, res);
    }

    private static int OptimizeEmbeddedImages(PdfDocument doc, CompressionConfig cfg)
    {
        var visited = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var candidates = new List<PdfDictionary>();

        foreach (PdfObject obj in doc.Internals.GetAllObjects())
        {
            if (obj is PdfDictionary dict &&
                dict.Elements.GetName("/Subtype") == "/Image" &&
                visited.Add(dict))
            {
                candidates.Add(dict);
            }
        }

        int optimizedCount = 0;
        int maxPixelCap = cfg.DownsampleImages ? Math.Max(128, (int)Math.Round(cfg.TargetDpi * 11.7)) : 0;

        foreach (var imageDict in candidates)
        {
            try
            {
                if (TryRecompressImageObject(imageDict, cfg, maxPixelCap))
                {
                    optimizedCount++;
                }
            }
            catch
            {
                // Never abort whole PDF if one exotic XObject cannot be re-encoded
            }
        }

        return optimizedCount;
    }

    private static bool TryRecompressImageObject(PdfDictionary dict, CompressionConfig cfg, int maxPixelCap)
    {
        if (dict.Stream?.Value is not { Length: > 4096 } rawCompressed)
            return false;

        // Skip image masks or images carrying separate alpha SMask to preserve transparency faithfully
        if (dict.Elements.GetBoolean("/ImageMask"))
            return false;
        if (dict.Elements.ContainsKey("/SMask") || dict.Elements.ContainsKey("/Mask"))
            return false;

        int width = dict.Elements.GetInteger("/Width");
        int height = dict.Elements.GetInteger("/Height");
        int bpc = dict.Elements.GetInteger("/BitsPerComponent");
        if (bpc == 0) bpc = 8;

        // Protect 1-bit monochrome CCITT/JBIG2 text scans and tiny icons
        if (bpc == 1 || width <= 0 || height <= 0 || (long)width * height < 4096)
            return false;

        string filterName = ExtractPrimaryFilter(dict);
        string colorSpace = ExtractColorSpaceName(dict);

        using SKBitmap? decoded = DecodePdfImage(dict, rawCompressed, filterName, colorSpace, width, height, bpc);
        if (decoded is null || decoded.Width <= 0 || decoded.Height <= 0)
            return false;

        int newW = decoded.Width;
        int newH = decoded.Height;
        if (cfg.DownsampleImages && maxPixelCap > 0)
        {
            double scale = Math.Min((double)maxPixelCap / newW, (double)maxPixelCap / newH);
            if (scale < 0.92)
            {
                newW = Math.Max(16, (int)Math.Round(newW * scale));
                newH = Math.Max(16, (int)Math.Round(newH * scale));
            }
        }

        bool wantGray = cfg.Grayscale || colorSpace == "/DeviceGray" || decoded.ColorType == SKColorType.Gray8;
        var targetInfo = new SKImageInfo(
            newW,
            newH,
            wantGray ? SKColorType.Gray8 : SKColorType.Rgba8888,
            SKAlphaType.Opaque);

        using var targetBitmap = new SKBitmap(targetInfo);
        using (var canvas = new SKCanvas(targetBitmap))
        {
            canvas.Clear(SKColors.White);
            using var paint = new SKPaint
            {
                FilterQuality = SKFilterQuality.High,
                IsAntialias = true
            };
            if (wantGray && decoded.ColorType != SKColorType.Gray8)
            {
                paint.ColorFilter = SKColorFilter.CreateColorMatrix(
                [
                    0.299f, 0.587f, 0.114f, 0, 0,
                    0.299f, 0.587f, 0.114f, 0, 0,
                    0.299f, 0.587f, 0.114f, 0, 0,
                    0,      0,      0,      1, 0
                ]);
            }
            canvas.DrawBitmap(decoded, new SKRect(0, 0, newW, newH), paint);
        }

        using var skImage = SKImage.FromBitmap(targetBitmap);
        using SKData? encoded = skImage.Encode(SKEncodedImageFormat.Jpeg, Math.Clamp(cfg.JpegQuality, 15, 95));
        if (encoded is null)
            return false;

        byte[] jpegBytes = encoded.ToArray();
        if (jpegBytes.Length >= rawCompressed.Length - 512 || jpegBytes.Length >= rawCompressed.Length * 0.96)
            return false;

        dict.Stream.Value = jpegBytes;
        dict.Elements.SetInteger("/Width", newW);
        dict.Elements.SetInteger("/Height", newH);
        dict.Elements.SetInteger("/BitsPerComponent", 8);
        dict.Elements.Remove("/ColorSpace");
        dict.Elements.SetName("/ColorSpace", wantGray ? "/DeviceGray" : "/DeviceRGB");
        dict.Elements.Remove("/Filter");
        dict.Elements.SetName("/Filter", "/DCTDecode");
        dict.Elements.Remove("/DecodeParms");
        dict.Elements.Remove("/Decode");
        dict.Elements.SetInteger("/Length", jpegBytes.Length);

        return true;
    }

    private static SKBitmap? DecodePdfImage(
        PdfDictionary dict,
        byte[] rawCompressed,
        string filterName,
        string colorSpace,
        int width,
        int height,
        int bpc)
    {
        if (filterName is "/DCTDecode" or "/JPXDecode")
        {
            return SKBitmap.Decode(rawCompressed);
        }

        if ((filterName is "/FlateDecode" or "") && bpc == 8)
        {
            byte[]? unfiltered = filterName == "" ? rawCompressed : TryGetUnfilteredBytes(dict);
            if (unfiltered is null) return null;

            int channels = colorSpace switch
            {
                "/DeviceGray" => 1,
                "/DeviceRGB" => 3,
                "/DeviceCMYK" => 4,
                _ => 0
            };
            if (channels == 0) return null;

            // Handle PNG scanline predictor (/Predictor >= 10) if present in /DecodeParms
            if (dict.Elements.GetDictionary("/DecodeParms") is { } parms)
            {
                int predictor = parms.Elements.GetInteger("/Predictor");
                if (predictor >= 10)
                {
                    unfiltered = UnfilterPngRows(unfiltered, width, height, channels);
                    if (unfiltered is null) return null;
                }
            }

            int expectedLen = width * height * channels;
            if (unfiltered.Length < expectedLen) return null;

            if (channels == 1)
            {
                var bmp = new SKBitmap(new SKImageInfo(width, height, SKColorType.Gray8, SKAlphaType.Opaque));
                System.Runtime.InteropServices.Marshal.Copy(unfiltered, 0, bmp.GetPixels(), expectedLen);
                return bmp;
            }
            if (channels == 3)
            {
                var bmp = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Opaque));
                byte[] rgba = new byte[width * height * 4];
                int s = 0, d = 0;
                int pixels = width * height;
                for (int i = 0; i < pixels; i++)
                {
                    rgba[d] = unfiltered[s];
                    rgba[d + 1] = unfiltered[s + 1];
                    rgba[d + 2] = unfiltered[s + 2];
                    rgba[d + 3] = 255;
                    s += 3;
                    d += 4;
                }
                System.Runtime.InteropServices.Marshal.Copy(rgba, 0, bmp.GetPixels(), rgba.Length);
                return bmp;
            }
            if (channels == 4)
            {
                var bmp = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Opaque));
                byte[] rgba = new byte[width * height * 4];
                int s = 0, d = 0;
                int pixels = width * height;
                for (int i = 0; i < pixels; i++)
                {
                    int c = unfiltered[s], m = unfiltered[s + 1], y = unfiltered[s + 2], k = unfiltered[s + 3];
                    rgba[d] = (byte)((255 - c) * (255 - k) / 255);
                    rgba[d + 1] = (byte)((255 - m) * (255 - k) / 255);
                    rgba[d + 2] = (byte)((255 - y) * (255 - k) / 255);
                    rgba[d + 3] = 255;
                    s += 4;
                    d += 4;
                }
                System.Runtime.InteropServices.Marshal.Copy(rgba, 0, bmp.GetPixels(), rgba.Length);
                return bmp;
            }
        }

        return null;
    }

    private static byte[]? TryGetUnfilteredBytes(PdfDictionary dict)
    {
        try { return dict.Stream?.UnfilteredValue; }
        catch { return null; }
    }

    private static byte[]? UnfilterPngRows(byte[] src, int width, int height, int bpp)
    {
        int rowBytes = width * bpp;
        int stride = rowBytes + 1;
        if (src.Length < stride * height) return null;

        byte[] dst = new byte[rowBytes * height];
        for (int y = 0; y < height; y++)
        {
            int srcRow = y * stride;
            int dstRow = y * rowBytes;
            int prevRow = (y - 1) * rowBytes;
            byte filter = src[srcRow];

            for (int x = 0; x < rowBytes; x++)
            {
                byte raw = src[srcRow + 1 + x];
                byte left = x >= bpp ? dst[dstRow + x - bpp] : (byte)0;
                byte up = y > 0 ? dst[prevRow + x] : (byte)0;
                byte upLeft = (y > 0 && x >= bpp) ? dst[prevRow + x - bpp] : (byte)0;

                dst[dstRow + x] = filter switch
                {
                    0 => raw,
                    1 => (byte)(raw + left),
                    2 => (byte)(raw + up),
                    3 => (byte)(raw + ((left + up) >> 1)),
                    4 => (byte)(raw + PaethPredictor(left, up, upLeft)),
                    _ => raw
                };
            }
        }
        return dst;
    }

    private static int PaethPredictor(int a, int b, int c)
    {
        int p = a + b - c;
        int pa = Math.Abs(p - a);
        int pb = Math.Abs(p - b);
        int pc = Math.Abs(p - c);
        if (pa <= pb && pa <= pc) return a;
        return pb <= pc ? b : c;
    }

    private static string ExtractPrimaryFilter(PdfDictionary dict)
    {
        if (!dict.Elements.ContainsKey("/Filter")) return "";
        PdfItem? item = dict.Elements["/Filter"];
        if (item is PdfReference r) item = r.Value;
        if (item is PdfName n) return n.Value;
        if (item is PdfArray arr && arr.Elements.Count > 0)
        {
            PdfItem first = arr.Elements[0];
            if (first is PdfReference fr && fr.Value is not null) first = fr.Value;
            if (first is PdfName fn) return fn.Value;
        }
        return "";
    }

    private static string ExtractColorSpaceName(PdfDictionary dict)
    {
        if (!dict.Elements.ContainsKey("/ColorSpace")) return "";
        PdfItem? item = dict.Elements["/ColorSpace"];
        if (item is PdfReference r) item = r.Value;
        if (item is PdfName n) return n.Value;
        if (item is PdfArray arr && arr.Elements.Count > 0 && arr.Elements[0] is PdfName fn)
        {
            if (fn.Value == "/ICCBased" && arr.Elements.Count > 1)
            {
                PdfItem? profile = arr.Elements[1];
                if (profile is PdfReference pr) profile = pr.Value;
                if (profile is PdfDictionary pd)
                {
                    return pd.Elements.GetInteger("/N") switch
                    {
                        1 => "/DeviceGray",
                        3 => "/DeviceRGB",
                        4 => "/DeviceCMYK",
                        _ => ""
                    };
                }
            }
            return fn.Value;
        }
        return "";
    }

    private static bool VerifyIntegrity(string pdfPath, int expectedPages)
    {
        try
        {
            using var check = PdfReader.Open(pdfPath, PdfDocumentOpenMode.Import);
            return check.PageCount == expectedPages;
        }
        catch
        {
            return false;
        }
    }

    private static bool PathsEqual(string a, string b) =>
        string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    private static void CopyEnsuringDirectory(string src, string dst)
    {
        if (Path.GetDirectoryName(dst) is { Length: > 0 } dir)
            Directory.CreateDirectory(dir);
        File.Copy(src, dst, overwrite: true);
    }
}
