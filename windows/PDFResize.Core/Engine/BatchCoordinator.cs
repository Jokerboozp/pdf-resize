using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using PDFResize.Core.Models;

namespace PDFResize.Core.Engine;

public sealed record WorkerTaskPayload(
    long FileId,
    string SourcePath,
    string DestinationPath,
    string? BackupPath,
    bool Inplace,
    CompressionConfig Config
);

public static class WorkerCli
{
    /// <summary>
    /// Handles isolated child worker invocation (`PDFResize.exe --worker-one req.json resp.json`)
    /// and headless native runtime verification (`PDFResize.exe --self-test`).
    /// </summary>
    public static bool TryRun(string[] args)
    {
        if (args.Length >= 1 && args[0] == "--self-test")
        {
            return RunSelfTest();
        }

        if (args.Length < 3 || args[0] != "--worker-one")
            return false;

        try
        {
            string reqJson = File.ReadAllText(args[1]);
            var payload = JsonSerializer.Deserialize<WorkerTaskPayload>(reqJson)
                          ?? throw new InvalidOperationException("Invalid worker payload");
            var res = PdfCompressor.CompressFile(
                payload.SourcePath,
                payload.DestinationPath,
                payload.Config,
                payload.Inplace,
                payload.BackupPath);
            File.WriteAllText(args[2], JsonSerializer.Serialize(res));
            return true;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Worker error: {ex}");
            Environment.ExitCode = 2;
            return true;
        }
    }

    private static bool RunSelfTest()
    {
        string tempDir = Path.Combine(Path.GetTempPath(), $"pdfresize_selftest_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        try
        {
            // 1. Verify native e_sqlite3 WAL store
            using (var store = new JobStore(Path.Combine(tempDir, "selftest.sqlite3")))
            {
                store.RecordFingerprint(Path.Combine(tempDir, "dummy.pdf"), 1024, 1700000000.0, CompressionPreset.Balanced);
                if (store.GetAllFingerprints().Count != 1)
                    throw new InvalidOperationException("SQLite fingerprint verification failed");
            }

            // 2. Verify native SkiaSharp + PDFsharp compression pipeline
            string pdfPath = Path.Combine(tempDir, "sample.pdf");
            using (var bmp = new SkiaSharp.SKBitmap(new SkiaSharp.SKImageInfo(1200, 1200, SkiaSharp.SKColorType.Rgba8888, SkiaSharp.SKAlphaType.Opaque)))
            {
                using (var canvas = new SkiaSharp.SKCanvas(bmp))
                {
                    canvas.Clear(new SkiaSharp.SKColor(40, 110, 200));
                    using var paint = new SkiaSharp.SKPaint { Color = SkiaSharp.SKColors.Orange, StrokeWidth = 4 };
                    for (int i = 0; i < 1200; i += 20)
                        canvas.DrawLine(i, 0, 1200 - i, 1200, paint);
                }
                using var skImg = SkiaSharp.SKImage.FromBitmap(bmp);
                using var jpeg = skImg.Encode(SkiaSharp.SKEncodedImageFormat.Jpeg, 95);

                using var doc = new PdfSharp.Pdf.PdfDocument();
                var page = doc.AddPage();
                var imgDict = new PdfSharp.Pdf.PdfDictionary(doc);
                imgDict.Elements.SetName("/Type", "/XObject");
                imgDict.Elements.SetName("/Subtype", "/Image");
                imgDict.Elements.SetInteger("/Width", 1200);
                imgDict.Elements.SetInteger("/Height", 1200);
                imgDict.Elements.SetInteger("/BitsPerComponent", 8);
                imgDict.Elements.SetName("/ColorSpace", "/DeviceRGB");
                imgDict.Elements.SetName("/Filter", "/DCTDecode");
                imgDict.CreateStream(jpeg.ToArray());
                doc.Internals.AddObject(imgDict);

                var xObjs = new PdfSharp.Pdf.PdfDictionary(doc);
                xObjs.Elements["/Im0"] = imgDict.Reference!;
                var resDict = new PdfSharp.Pdf.PdfDictionary(doc);
                resDict.Elements["/XObject"] = xObjs;
                page.Elements["/Resources"] = resDict;
                page.Contents.AppendContent().CreateStream(System.Text.Encoding.ASCII.GetBytes("q 450 0 0 450 50 200 cm /Im0 Do Q"));
                doc.Save(pdfPath);
            }

            var res = PdfCompressor.CompressFile(pdfPath, pdfPath, CompressionConfig.ForPreset(CompressionPreset.Balanced), inplace: true);
            if (res.Status != FileProcessStatus.Done || res.SavedBytes <= 0)
                throw new InvalidOperationException($"Unexpected compression self-test status: {res.Status} ({res.ErrorMessage})");

            Console.WriteLine($"SELF_TEST_OK orig={res.OriginalSize} new={res.NewSize} saved={res.SavedBytes}");
            Environment.ExitCode = 0;
            return true;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"SELF_TEST_FAILED: {ex}");
            Environment.ExitCode = 3;
            return true;
        }
        finally
        {
            try { Directory.Delete(tempDir, recursive: true); } catch { /* ignore */ }
        }
    }
}

public sealed class BatchCoordinator : IDisposable
{
    public JobStore Store { get; }
    private readonly bool _useSubprocess;
    private readonly string? _selfExecutablePath;
    private readonly ConcurrentDictionary<string, JobControlToken> _activeTokens = new();
    private readonly object _speedLock = new();
    private readonly Queue<(double Ts, long Bytes)> _speedWindow = new();

    public event Action? StateChanged;

    public double BytesPerSecond { get; private set; }
    public int? EtaSeconds { get; private set; }
    public IReadOnlyList<string> ActiveFiles => _activeFileMap.Values.Take(6).ToList();
    private readonly ConcurrentDictionary<long, string> _activeFileMap = new();

    private sealed class JobControlToken
    {
        public volatile bool PauseRequested;
        public volatile bool CancelRequested;
    }

    public BatchCoordinator(JobStore? store = null, bool? useSubprocessIsolation = null)
    {
        Store = store ?? new JobStore();
        Store.RecoverInterruptedJobs();

        string? procPath = Environment.ProcessPath;
        bool isAppExe = procPath is not null &&
                        Path.GetFileNameWithoutExtension(procPath).Equals("PDFResize", StringComparison.OrdinalIgnoreCase);
        _selfExecutablePath = isAppExe ? procPath : null;
        _useSubprocess = useSubprocessIsolation ?? isAppExe;
    }

    public JobRecord CreateAndStartLocalJob(
        IReadOnlyList<string> sourcePaths,
        OutputMode outputMode,
        string? outputDir,
        string? backupDir,
        CompressionConfig config,
        bool recursive = true,
        int? limitFiles = null,
        string? customName = null,
        bool autoStart = true)
    {
        if (sourcePaths.Count == 0)
            throw new ArgumentException("请先添加至少一个文件夹或 PDF 文件");

        if (outputMode == OutputMode.OutputDirectory && string.IsNullOrWhiteSpace(outputDir))
            throw new ArgumentException("选择「另存到新文件夹」时，必须指定导出目录");

        var excludes = new List<string>();
        if (!string.IsNullOrWhiteSpace(outputDir)) excludes.Add(outputDir);
        if (!string.IsNullOrWhiteSpace(backupDir)) excludes.Add(backupDir);

        var fps = (config.SkipAlreadyOptimized && outputMode == OutputMode.Inplace)
            ? Store.GetAllFingerprints()
            : null;

        var scan = DirectoryScanner.Scan(
            sourcePaths,
            recursive: recursive,
            skipSmallerThanKb: config.SkipSmallerThanKb,
            fingerprints: fps,
            limitFiles: limitFiles,
            excludeDirectories: excludes);

        if (scan.TotalFiles == 0)
        {
            if (scan.AlreadyOptimizedCount > 0)
            {
                throw new InvalidOperationException(
                    $"所选目录中的 {scan.AlreadyOptimizedCount} 个 PDF 均已在之前优化过。如需重新试跑或再次压缩，请在设置中点击「重置跳过缓存」或关闭「跳过历史已优化文件」。");
            }
            if (scan.TooSmallCount > 0)
                throw new InvalidOperationException($"所选目录中的 {scan.TooSmallCount} 个 PDF 均小于最小跳过体积阈值。");
            throw new InvalidOperationException("所选路径中未找到任何 PDF 文件。");
        }

        string jobId = Guid.NewGuid().ToString("N")[..12];
        string jobName = !string.IsNullOrWhiteSpace(customName)
            ? customName.Trim()
            : sourcePaths.Count == 1
                ? $"{Path.GetFileName(sourcePaths[0].TrimEnd('\\', '/'))} ({scan.TotalFiles} 个 PDF)"
                : $"{sourcePaths.Count} 个目录合并 ({scan.TotalFiles} 个 PDF)";

        string? resolvedOut = !string.IsNullOrWhiteSpace(outputDir) ? Path.GetFullPath(outputDir) : null;
        string? resolvedBkp = !string.IsNullOrWhiteSpace(backupDir) ? Path.GetFullPath(backupDir) : null;

        var mapped = scan.Entries.Select(e =>
        {
            string dst = outputMode == OutputMode.Inplace
                ? e.SourcePath
                : Path.Combine(resolvedOut!, e.RelativePath);
            string? bkp = (outputMode == OutputMode.Inplace && resolvedBkp is not null)
                ? Path.Combine(resolvedBkp, e.RelativePath)
                : null;
            return (e, dst, bkp);
        }).ToList();

        var job = Store.CreateJob(
            jobId,
            jobName,
            string.Join(" ; ", sourcePaths),
            outputMode,
            resolvedOut,
            resolvedBkp,
            config,
            mapped);

        if (autoStart)
            StartJob(job.Id);
        else
            NotifyChanged();

        return Store.GetJob(job.Id)!;
    }

    public bool StartJob(string jobId)
    {
        var job = Store.GetJob(jobId) ?? throw new KeyNotFoundException("任务不存在");
        var token = new JobControlToken();
        if (!_activeTokens.TryAdd(jobId, token))
            return false;

        Store.ResetJobProcessingToPending(jobId);
        Store.UpdateJobStatus(jobId, JobStatus.Running, setStarted: true);
        lock (_speedLock) { _speedWindow.Clear(); }
        NotifyChanged();

        _ = Task.Run(() => RunJobAsync(jobId, job.Config, job.OutputMode == OutputMode.Inplace, token));
        return true;
    }

    private async Task RunJobAsync(string jobId, CompressionConfig config, bool inplace, JobControlToken token)
    {
        try
        {
            var stats0 = Store.GetJobStats(jobId);
            if (stats0.Pending == 0)
            {
                Store.UpdateJobStatus(jobId, JobStatus.Completed, setFinished: true);
                return;
            }

            int workers = Math.Max(1, Math.Min(config.Workers, Environment.ProcessorCount));
            var workerTasks = Enumerable.Range(0, workers)
                .Select(_ => Task.Run(() => WorkerLoop(jobId, config, inplace, token)))
                .ToArray();

            await Task.WhenAll(workerTasks).ConfigureAwait(false);

            if (token.CancelRequested)
            {
                Store.ResetJobProcessingToPending(jobId);
                Store.UpdateJobStatus(jobId, JobStatus.Cancelled, setFinished: true);
            }
            else if (token.PauseRequested)
            {
                Store.ResetJobProcessingToPending(jobId);
                Store.UpdateJobStatus(jobId, JobStatus.Paused);
            }
            else
            {
                Store.UpdateJobStatus(jobId, JobStatus.Completed, setFinished: true);
            }
        }
        catch
        {
            Store.ResetJobProcessingToPending(jobId);
            Store.UpdateJobStatus(jobId, JobStatus.Failed, setFinished: true);
        }
        finally
        {
            _activeTokens.TryRemove(jobId, out _);
            _activeFileMap.Clear();
            BytesPerSecond = 0;
            EtaSeconds = null;
            NotifyChanged();
        }
    }

    private void WorkerLoop(string jobId, CompressionConfig config, bool inplace, JobControlToken token)
    {
        while (!token.PauseRequested && !token.CancelRequested)
        {
            var batch = Store.ClaimPendingFiles(jobId, limit: 2);
            if (batch.Count == 0) break;

            foreach (var row in batch)
                _activeFileMap[row.Id] = Path.GetFileName(row.RelativePath);
            NotifyChanged();

            foreach (var row in batch)
            {
                if (token.PauseRequested || token.CancelRequested)
                    break;

                SingleCompressionResult res = (_useSubprocess && _selfExecutablePath is not null)
                    ? RunInIsolatedSubprocess(row, config, inplace)
                    : PdfCompressor.CompressFile(row.SourcePath, row.DestinationPath, config, inplace, row.BackupPath);

                Store.UpdateFileResult(row.Id, res);
                if (inplace && res.Status is FileProcessStatus.Done or FileProcessStatus.SkippedNoGain)
                {
                    double mt = res.NewModificationTimeUnix ?? row.ModificationTimeUnix;
                    Store.RecordFingerprint(row.SourcePath, res.NewSize, mt, config.Preset);
                }

                _activeFileMap.TryRemove(row.Id, out _);
                RecordThroughput(jobId, row.OriginalSize);
                NotifyChanged();
            }
        }
    }

    private SingleCompressionResult RunInIsolatedSubprocess(JobFileRow row, CompressionConfig cfg, bool inplace)
    {
        string tmp = Path.GetTempPath();
        string uid = Guid.NewGuid().ToString("N");
        string reqPath = Path.Combine(tmp, $"pdfresize_req_{uid}.json");
        string respPath = Path.Combine(tmp, $"pdfresize_resp_{uid}.json");

        try
        {
            var payload = new WorkerTaskPayload(row.Id, row.SourcePath, row.DestinationPath, row.BackupPath, inplace, cfg);
            File.WriteAllText(reqPath, JsonSerializer.Serialize(payload));

            var psi = new ProcessStartInfo
            {
                FileName = _selfExecutablePath!,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            psi.ArgumentList.Add("--worker-one");
            psi.ArgumentList.Add(reqPath);
            psi.ArgumentList.Add(respPath);

            using var proc = Process.Start(psi);
            if (proc is null)
                throw new InvalidOperationException("无法启动隔离子进程");

            proc.WaitForExit();
            if (proc.ExitCode == 0 && File.Exists(respPath))
            {
                var parsed = JsonSerializer.Deserialize<SingleCompressionResult>(File.ReadAllText(respPath));
                if (parsed is not null) return parsed;
            }

            return new SingleCompressionResult
            {
                Status = FileProcessStatus.Failed,
                OriginalSize = row.OriginalSize,
                NewSize = row.OriginalSize,
                ErrorMessage = $"子工作进程异常退出 (code {proc.ExitCode})"
            };
        }
        catch (Exception ex)
        {
            return new SingleCompressionResult
            {
                Status = FileProcessStatus.Failed,
                OriginalSize = row.OriginalSize,
                NewSize = row.OriginalSize,
                ErrorMessage = ex.Message
            };
        }
        finally
        {
            try { if (File.Exists(reqPath)) File.Delete(reqPath); } catch { /* ignore */ }
            try { if (File.Exists(respPath)) File.Delete(respPath); } catch { /* ignore */ }
        }
    }

    private void RecordThroughput(string jobId, long origBytes)
    {
        double now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        lock (_speedLock)
        {
            _speedWindow.Enqueue((now, origBytes));
            while (_speedWindow.Count > 0 && now - _speedWindow.Peek().Ts > 25.0)
                _speedWindow.Dequeue();

            long sum = _speedWindow.Sum(x => x.Bytes);
            double earliest = _speedWindow.Count > 0 ? _speedWindow.Peek().Ts : now;
            double elapsed = Math.Max(0.8, now - earliest);
            BytesPerSecond = sum > 0 ? sum / elapsed : 0;
        }

        var st = Store.GetJobStats(jobId);
        long rem = Math.Max(0, st.TotalOriginalBytes - st.ProcessedOriginalBytes);
        EtaSeconds = BytesPerSecond > 1024 ? (int)(rem / BytesPerSecond) : null;
    }

    public void PauseJob(string jobId)
    {
        if (_activeTokens.TryGetValue(jobId, out var t))
            t.PauseRequested = true;
    }

    public void CancelJob(string jobId)
    {
        if (_activeTokens.TryGetValue(jobId, out var t))
        {
            t.CancelRequested = true;
        }
        else
        {
            Store.UpdateJobStatus(jobId, JobStatus.Cancelled, setFinished: true);
            NotifyChanged();
        }
    }

    public int RetryFailed(string jobId)
    {
        int count = Store.RetryFailedFiles(jobId);
        if (count > 0) StartJob(jobId);
        return count;
    }

    public bool IsJobActive(string jobId) => _activeTokens.ContainsKey(jobId);

    public void DeleteJob(string jobId)
    {
        if (IsJobActive(jobId)) return;
        Store.DeleteJob(jobId);
        NotifyChanged();
    }

    private void NotifyChanged() => StateChanged?.Invoke();

    public void Dispose() => Store.Dispose();
}
