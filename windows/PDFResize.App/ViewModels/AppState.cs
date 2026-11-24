using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PDFResize.Core.Engine;
using PDFResize.Core.Models;

namespace PDFResize.App.ViewModels;

public sealed class AppState : IDisposable
{
    public BatchCoordinator Coordinator { get; }

    // Shared Workbench state persisted across page switches
    public List<string> SourcePaths { get; } = [];
    public bool RecursiveScan { get; set; } = true;
    public CompressionConfig Config { get; set; } = CompressionConfig.ForPreset(CompressionPreset.Balanced);
    public OutputMode OutputMode { get; set; } = OutputMode.Inplace;
    public string OutputDirectory { get; set; } = string.Empty;
    public string BackupDirectory { get; set; } = string.Empty;
    public int? TrialLimitFiles { get; set; } = null;
    public ScanSummary? LatestScan { get; set; }

    // Compare state
    public string? ComparePdfPath { get; set; }

    // Active / selected job ID in JobsPage
    public string? SelectedJobId { get; set; }

    // Appearance preference
    public ElementTheme ThemePreference { get; set; } = ElementTheme.Default;

    public event Action? SourcesChanged;
    public event Action? ConfigChanged;
    public event Action<string>? NavigateRequested;
    public event Action<string, string, InfoBarSeverity>? BannerRequested;
    public event Action<ElementTheme>? ThemeChanged;

    public AppState()
    {
        Coordinator = new BatchCoordinator();
        var existingJobs = Coordinator.Store.ListJobs(1);
        if (existingJobs.Count > 0)
        {
            SelectedJobId = existingJobs[0].Id;
        }
    }

    public int AddSources(IEnumerable<string> paths)
    {
        int added = 0;
        foreach (string raw in paths)
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            string full;
            try { full = Path.GetFullPath(raw.Trim().Trim('"')); }
            catch { continue; }

            if (Directory.Exists(full))
            {
                if (!SourcePaths.Any(p => string.Equals(p, full, StringComparison.OrdinalIgnoreCase)))
                {
                    SourcePaths.Add(full);
                    added++;
                }
            }
            else if (File.Exists(full) && full.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
            {
                if (!SourcePaths.Any(p => string.Equals(p, full, StringComparison.OrdinalIgnoreCase)))
                {
                    SourcePaths.Add(full);
                    added++;
                }
                ComparePdfPath ??= full;
            }
        }

        if (added > 0)
            SourcesChanged?.Invoke();
        return added;
    }

    public void RemoveSource(string path)
    {
        int removed = SourcePaths.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        if (removed > 0)
        {
            if (SourcePaths.Count == 0)
                LatestScan = null;
            SourcesChanged?.Invoke();
        }
    }

    public void ClearSources()
    {
        SourcePaths.Clear();
        LatestScan = null;
        SourcesChanged?.Invoke();
    }

    public void NotifyConfigChanged() => ConfigChanged?.Invoke();

    public void OpenInCompare(string pdfPath)
    {
        if (string.IsNullOrWhiteSpace(pdfPath) || !File.Exists(pdfPath)) return;
        ComparePdfPath = Path.GetFullPath(pdfPath);
        NavigateRequested?.Invoke("compare");
    }

    public void OpenJobMonitor(string jobId)
    {
        SelectedJobId = jobId;
        NavigateRequested?.Invoke("jobs");
    }

    public void ShowBanner(string title, string message, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        BannerRequested?.Invoke(title, message, severity);
    }

    public void SetTheme(ElementTheme theme)
    {
        ThemePreference = theme;
        ThemeChanged?.Invoke(theme);
    }

    public void Dispose() => Coordinator.Dispose();
}
