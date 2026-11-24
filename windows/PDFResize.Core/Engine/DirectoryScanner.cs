using PDFResize.Core.Models;

namespace PDFResize.Core.Engine;

public static class DirectoryScanner
{
    public static ScanSummary Scan(
        IEnumerable<string> rawSources,
        bool recursive = true,
        int skipSmallerThanKb = 0,
        IReadOnlyDictionary<string, (long Size, double Mtime)>? fingerprints = null,
        int? limitFiles = null,
        IEnumerable<string>? excludeDirectories = null)
    {
        var sourceList = rawSources
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .Select(s => Path.GetFullPath(s.Trim().Trim('"')))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (sourceList.Count == 0)
            throw new ArgumentException("请至少添加一个有效的文件夹或 PDF 路径");

        var excludedSet = new HashSet<string>(
            (excludeDirectories ?? [])
                .Where(s => !string.IsNullOrWhiteSpace(s))
                .Select(s => Path.GetFullPath(s).TrimEnd('\\', '/')),
            StringComparer.OrdinalIgnoreCase);

        var labelCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var normalizedSources = new List<(string Path, bool IsDir, string Label)>();

        foreach (string p in sourceList)
        {
            bool isDir = Directory.Exists(p);
            bool isFile = !isDir && File.Exists(p);
            if (!isDir && !isFile)
                throw new DirectoryNotFoundException($"路径不存在或无访问权限: {p}");

            string baseName = Path.GetFileName(p.TrimEnd('\\', '/'));
            if (string.IsNullOrEmpty(baseName))
                baseName = p.Replace(":", "").Replace("\\", "").Replace("/", "");

            int count = labelCounts.GetValueOrDefault(baseName, 0) + 1;
            labelCounts[baseName] = count;
            string label = count == 1 ? baseName : $"{baseName}_{count}";
            normalizedSources.Add((p, isDir, label));
        }

        bool multiSource = normalizedSources.Count > 1;
        long minBytes = Math.Max(0, skipSmallerThanKb) * 1024L;

        var entries = new List<ScannedFileEntry>();
        var seenFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var sourceSummaries = new List<SourceFolderSummary>();

        long totalBytes = 0;
        int pendingTotal = 0;
        int alreadyOptimizedCount = 0;
        int tooSmallCount = 0;

        ScannedFileEntry? InspectFile(string filePath, string relPath)
        {
            string name = Path.GetFileName(filePath);
            if (!name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ||
                name.EndsWith(PdfCompressor.TempSuffix, StringComparison.OrdinalIgnoreCase) ||
                name.StartsWith("._", StringComparison.Ordinal))
            {
                return null;
            }

            string full = Path.GetFullPath(filePath);
            if (!seenFiles.Add(full))
                return null;

            FileInfo fi;
            try
            {
                fi = new FileInfo(full);
                if (!fi.Exists) return null;
            }
            catch { return null; }

            long size = fi.Length;
            double mtime = new DateTimeOffset(fi.LastWriteTimeUtc, TimeSpan.Zero).ToUnixTimeMilliseconds() / 1000.0;

            var status = FileProcessStatus.Pending;
            if (fingerprints is not null && fingerprints.TryGetValue(full.ToLowerInvariant(), out var fp))
            {
                if (fp.Size == size && Math.Abs(fp.Mtime - mtime) < 2.0)
                {
                    status = FileProcessStatus.SkippedAlreadyDone;
                    alreadyOptimizedCount++;
                }
            }

            if (status == FileProcessStatus.Pending && minBytes > 0 && size < minBytes)
            {
                status = FileProcessStatus.SkippedSmall;
                tooSmallCount++;
            }

            // When trial LimitFiles is active, only count pending files so subsequent trial runs advance cleanly
            if (limitFiles is > 0 && status != FileProcessStatus.Pending)
                return null;

            return new ScannedFileEntry(relPath, full, size, mtime, status);
        }

        foreach (var src in normalizedSources)
        {
            int sCount = 0;
            long sBytes = 0;
            int sPending = 0;

            if (!src.IsDir)
            {
                if (limitFiles is > 0 && pendingTotal >= limitFiles.Value)
                    break;

                if (InspectFile(src.Path, Path.GetFileName(src.Path)) is { } single)
                {
                    entries.Add(single);
                    totalBytes += single.OriginalSize;
                    sCount++;
                    sBytes += single.OriginalSize;
                    if (single.InitialStatus == FileProcessStatus.Pending)
                    {
                        pendingTotal++;
                        sPending++;
                    }
                }

                sourceSummaries.Add(new SourceFolderSummary
                {
                    Path = src.Path,
                    IsDirectory = false,
                    TotalFiles = sCount,
                    TotalBytes = sBytes,
                    PendingCount = sPending
                });
                continue;
            }

            void WalkDirectory(string currentDir)
            {
                if (limitFiles is > 0 && pendingTotal >= limitFiles.Value)
                    return;

                string[] files;
                try
                {
                    files = Directory.GetFiles(currentDir, "*.pdf");
                    Array.Sort(files, StringComparer.OrdinalIgnoreCase);
                }
                catch { return; }

                foreach (string f in files)
                {
                    if (limitFiles is > 0 && pendingTotal >= limitFiles.Value)
                        return;

                    string innerRel = Path.GetRelativePath(src.Path, f);
                    string rel = multiSource ? Path.Combine(src.Label, innerRel) : innerRel;

                    if (InspectFile(f, rel) is { } entry)
                    {
                        entries.Add(entry);
                        totalBytes += entry.OriginalSize;
                        sCount++;
                        sBytes += entry.OriginalSize;
                        if (entry.InitialStatus == FileProcessStatus.Pending)
                        {
                            pendingTotal++;
                            sPending++;
                        }
                    }
                }

                if (!recursive) return;

                string[] subDirs;
                try
                {
                    subDirs = Directory.GetDirectories(currentDir);
                    Array.Sort(subDirs, StringComparer.OrdinalIgnoreCase);
                }
                catch { return; }

                foreach (string sub in subDirs)
                {
                    if (limitFiles is > 0 && pendingTotal >= limitFiles.Value)
                        return;

                    try
                    {
                        var di = new DirectoryInfo(sub);
                        if ((di.Attributes & FileAttributes.ReparsePoint) != 0)
                            continue;
                        if (excludedSet.Contains(di.FullName.TrimEnd('\\', '/')))
                            continue;
                        WalkDirectory(di.FullName);
                    }
                    catch { /* ignore inaccessible subfolders */ }
                }
            }

            WalkDirectory(src.Path);
            sourceSummaries.Add(new SourceFolderSummary
            {
                Path = src.Path,
                IsDirectory = true,
                TotalFiles = sCount,
                TotalBytes = sBytes,
                PendingCount = sPending
            });

            if (limitFiles is > 0 && pendingTotal >= limitFiles.Value)
                break;
        }

        var samples = entries
            .OrderByDescending(e => e.OriginalSize)
            .Take(20)
            .ToList();

        return new ScanSummary
        {
            TotalFiles = entries.Count,
            TotalBytes = totalBytes,
            PendingCount = pendingTotal,
            AlreadyOptimizedCount = alreadyOptimizedCount,
            TooSmallCount = tooSmallCount,
            Sources = sourceSummaries,
            LargestSamples = samples,
            Entries = entries
        };
    }
}
