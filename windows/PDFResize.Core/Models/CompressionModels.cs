using System.Text.Json.Serialization;

namespace PDFResize.Core.Models;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum CompressionPreset
{
    Lossless,
    Light,
    Balanced,
    Extreme,
    Custom
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum OutputMode
{
    Inplace,
    OutputDirectory
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum FileProcessStatus
{
    Pending,
    Processing,
    Done,
    SkippedNoGain,
    SkippedSmall,
    SkippedEncrypted,
    SkippedEmpty,
    SkippedAlreadyDone,
    Failed
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum JobStatus
{
    Created,
    Running,
    Paused,
    Completed,
    Cancelled,
    Failed
}

public sealed class CompressionConfig
{
    public CompressionPreset Preset { get; set; } = CompressionPreset.Balanced;
    public bool CompressImages { get; set; } = true;
    public bool DownsampleImages { get; set; } = true;
    public int TargetDpi { get; set; } = 150;
    public int JpegQuality { get; set; } = 70;
    public bool Grayscale { get; set; } = false;
    public bool StripMetadata { get; set; } = false;
    public double MinSavingPercent { get; set; } = 1.0;
    public int SkipSmallerThanKb { get; set; } = 0;
    public bool SkipAlreadyOptimized { get; set; } = true;
    public bool PreserveModificationDate { get; set; } = true;
    public int Workers { get; set; } = RecommendedWorkers();

    public static int RecommendedWorkers()
    {
        int cores = Environment.ProcessorCount;
        return Math.Max(1, Math.Min(cores > 4 ? cores - 2 : cores, 8));
    }

    public CompressionConfig Clone() => (CompressionConfig)MemberwiseClone();

    public static CompressionConfig ForPreset(CompressionPreset preset, int? workers = null)
    {
        int w = workers ?? RecommendedWorkers();
        return preset switch
        {
            CompressionPreset.Lossless => new CompressionConfig
            {
                Preset = CompressionPreset.Lossless,
                CompressImages = false,
                DownsampleImages = false,
                TargetDpi = 300,
                JpegQuality = 92,
                Grayscale = false,
                StripMetadata = false,
                MinSavingPercent = 0.5,
                Workers = w
            },
            CompressionPreset.Light => new CompressionConfig
            {
                Preset = CompressionPreset.Light,
                CompressImages = true,
                DownsampleImages = true,
                TargetDpi = 200,
                JpegQuality = 82,
                Grayscale = false,
                StripMetadata = false,
                MinSavingPercent = 1.0,
                Workers = w
            },
            CompressionPreset.Extreme => new CompressionConfig
            {
                Preset = CompressionPreset.Extreme,
                CompressImages = true,
                DownsampleImages = true,
                TargetDpi = 100,
                JpegQuality = 50,
                Grayscale = false,
                StripMetadata = true,
                MinSavingPercent = 1.0,
                Workers = w
            },
            _ => new CompressionConfig
            {
                Preset = preset,
                CompressImages = true,
                DownsampleImages = true,
                TargetDpi = 150,
                JpegQuality = 70,
                Grayscale = false,
                StripMetadata = false,
                MinSavingPercent = 1.0,
                Workers = w
            }
        };
    }

    public static string PresetTitle(CompressionPreset p) => p switch
    {
        CompressionPreset.Lossless => "无损清理",
        CompressionPreset.Light => "高清轻压",
        CompressionPreset.Balanced => "均衡推荐",
        CompressionPreset.Extreme => "极致瘦身",
        _ => "自定义参数"
    };

    public static string PresetSavingHint(CompressionPreset p) => p switch
    {
        CompressionPreset.Lossless => "约省 5%–20% · 仅流压缩清理",
        CompressionPreset.Light => "约省 25%–50% · 200 DPI / 82%",
        CompressionPreset.Balanced => "约省 45%–75% · 150 DPI / 70%",
        CompressionPreset.Extreme => "约省 65%–88% · 100 DPI / 50%",
        _ => "自定义参数"
    };
}

public sealed record ScannedFileEntry(
    string RelativePath,
    string SourcePath,
    long OriginalSize,
    double ModificationTimeUnix,
    FileProcessStatus InitialStatus
);

public sealed class SourceFolderSummary
{
    public required string Path { get; init; }
    public required bool IsDirectory { get; init; }
    public int TotalFiles { get; set; }
    public long TotalBytes { get; set; }
    public int PendingCount { get; set; }
    public string DisplayName => System.IO.Path.GetFileName(Path.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : Path;
    public string BadgeText => $"{TotalFiles:N0} 个 PDF · {ByteFormat.Format(TotalBytes)}";
}

public sealed class ScanSummary
{
    public required int TotalFiles { get; init; }
    public required long TotalBytes { get; init; }
    public required int PendingCount { get; init; }
    public required int AlreadyOptimizedCount { get; init; }
    public required int TooSmallCount { get; init; }
    public required List<SourceFolderSummary> Sources { get; init; }
    public required List<ScannedFileEntry> LargestSamples { get; init; }
    public required List<ScannedFileEntry> Entries { get; init; }
}

public sealed class SingleCompressionResult
{
    public FileProcessStatus Status { get; set; } = FileProcessStatus.Failed;
    public long OriginalSize { get; set; }
    public long NewSize { get; set; }
    public long SavedBytes { get; set; }
    public int DurationMs { get; set; }
    public int Pages { get; set; }
    public int ImagesOptimized { get; set; }
    public string? ErrorMessage { get; set; }
    public double? NewModificationTimeUnix { get; set; }
}

public sealed class JobStats
{
    public int TotalFiles { get; set; }
    public int Pending { get; set; }
    public int Processing { get; set; }
    public int Done { get; set; }
    public int Skipped { get; set; }
    public int Failed { get; set; }
    public long TotalOriginalBytes { get; set; }
    public long ProcessedOriginalBytes { get; set; }
    public long ProcessedNewBytes { get; set; }
    public long SavedBytes { get; set; }
    public int ImagesOptimized { get; set; }

    public int CompletedFiles => Done + Skipped + Failed;
    public double ProgressPercent => TotalOriginalBytes > 0
        ? Math.Clamp((double)ProcessedOriginalBytes / TotalOriginalBytes * 100.0, 0, 100)
        : (TotalFiles > 0 ? (double)CompletedFiles / TotalFiles * 100.0 : 0);

    public double SavingPercent => ProcessedOriginalBytes > 0
        ? (double)SavedBytes / ProcessedOriginalBytes * 100.0
        : 0;
}

public sealed class JobRecord
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string SourceSummary { get; init; }
    public required OutputMode OutputMode { get; init; }
    public string? OutputDir { get; init; }
    public string? BackupDir { get; init; }
    public required CompressionConfig Config { get; init; }
    public JobStatus Status { get; set; }
    public DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }
    public JobStats Stats { get; set; } = new();

    public string StatusDisplay => StatusHelp.Display(Status);
    public string SubtitleDisplay => $"{Stats.CompletedFiles:N0}/{Stats.TotalFiles:N0} 文件 · 省 {ByteFormat.Format(Stats.SavedBytes)}";
}

public sealed class JobFileRow
{
    public long Id { get; init; }
    public required string JobId { get; init; }
    public required string RelativePath { get; init; }
    public required string SourcePath { get; init; }
    public required string DestinationPath { get; init; }
    public string? BackupPath { get; init; }
    public long OriginalSize { get; init; }
    public double ModificationTimeUnix { get; init; }
    public long? NewSize { get; set; }
    public long SavedBytes { get; set; }
    public FileProcessStatus Status { get; set; }
    public string? ErrorMessage { get; set; }
    public int? DurationMs { get; set; }
    public int Pages { get; set; }

    public string OriginalSizeText => ByteFormat.Format(OriginalSize);
    public string NewSizeText => NewSize.HasValue ? ByteFormat.Format(NewSize.Value) : "—";
    public string SavedText => SavedBytes > 0 && OriginalSize > 0
        ? $"{ByteFormat.Format(SavedBytes)} (-{(double)SavedBytes / OriginalSize * 100.0:F1}%)"
        : "—";
    public string DurationText => DurationMs.HasValue ? $"{DurationMs.Value / 1000.0:F2}s" : "—";
    public string PagesText => Pages > 0 ? $"{Pages} 页" : "—";
    public string StatusText => StatusHelp.Display(Status);
    public string DetailHint => !string.IsNullOrWhiteSpace(ErrorMessage) ? ErrorMessage : SourcePath;
    public string EffectivePath => File.Exists(DestinationPath) ? DestinationPath : SourcePath;
}

public static class StatusHelp
{
    public static string Display(JobStatus st) => st switch
    {
        JobStatus.Created => "准备就绪",
        JobStatus.Running => "正在压缩",
        JobStatus.Paused => "已暂停",
        JobStatus.Completed => "已完成",
        JobStatus.Cancelled => "已取消",
        JobStatus.Failed => "异常中断",
        _ => st.ToString()
    };

    public static string Display(FileProcessStatus st) => st switch
    {
        FileProcessStatus.Pending => "等待中",
        FileProcessStatus.Processing => "处理中",
        FileProcessStatus.Done => "已优化",
        FileProcessStatus.SkippedNoGain => "已是最优",
        FileProcessStatus.SkippedSmall => "体积过小",
        FileProcessStatus.SkippedEncrypted => "密码保护",
        FileProcessStatus.SkippedEmpty => "空文件",
        FileProcessStatus.SkippedAlreadyDone => "历史已优化",
        FileProcessStatus.Failed => "失败",
        _ => st.ToString()
    };
}

public static class ByteFormat
{
    private static readonly string[] Units = ["B", "KB", "MB", "GB", "TB"];

    public static string Format(long bytes)
    {
        double val = bytes;
        int idx = 0;
        while (Math.Abs(val) >= 1024.0 && idx < Units.Length - 1)
        {
            val /= 1024.0;
            idx++;
        }
        return idx == 0 ? $"{val:F0} {Units[idx]}" : $"{val:F2} {Units[idx]}";
    }

    public static string FormatEta(int? seconds)
    {
        if (seconds is null or < 0) return "计算中…";
        int s = seconds.Value;
        if (s < 60) return $"{s} 秒";
        int m = s / 60;
        if (m < 60) return $"{m} 分 {s % 60} 秒";
        return $"{m / 60} 小时 {m % 60} 分";
    }
}
