using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PDFResize.App.Views;
using PDFResize.Core.Models;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;

namespace PDFResize.App;

public sealed partial class MainWindow : Window
{
    private bool _suppressNavEvent;

    public MainWindow()
    {
        _suppressNavEvent = true;
        InitializeComponent();

        ConfigureWindowChromeAndBackdrop();

        App.State.NavigateRequested += OnNavigateRequested;
        App.State.BannerRequested += OnBannerRequested;
        App.State.ThemeChanged += OnThemeChanged;
        App.State.Coordinator.StateChanged += OnCoordinatorStateChanged;
        Closed += OnWindowClosed;

        FooterWorkerHintText.Text = $"CPU {Environment.ProcessorCount} 线程 · 默认 {CompressionConfig.RecommendedWorkers()} 隔离进程";
        RefreshChromeMetrics();

        NavView.SelectedItem = NavWorkbench;
        _suppressNavEvent = false;
        ContentFrame.Navigate(typeof(WorkbenchPage));
    }

    private void ConfigureWindowChromeAndBackdrop()
    {
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        try
        {
            if (MicaController.IsSupported())
            {
                SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
            }
            else if (DesktopAcrylicController.IsSupported())
            {
                SystemBackdrop = new DesktopAcrylicBackdrop();
            }
        }
        catch
        {
            // Fallback gracefully to solid theme background on unsupported graphics adapters
        }

        try
        {
            string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
            if (File.Exists(iconPath))
            {
                AppWindow.SetIcon(iconPath);
            }

            AppWindow.Resize(new SizeInt32(1280, 860));
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary);
            if (area is not null)
            {
                int x = area.WorkArea.X + Math.Max(0, (area.WorkArea.Width - 1280) / 2);
                int y = area.WorkArea.Y + Math.Max(0, (area.WorkArea.Height - 860) / 2);
                AppWindow.Move(new PointInt32(x, y));
            }
        }
        catch
        {
            // Ignore non-critical window sizing errors on headless CI
        }
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_suppressNavEvent) return;

        if (args.IsSettingsSelected)
        {
            ContentFrame.Navigate(typeof(SettingsPage));
            return;
        }

        if (args.SelectedItemContainer?.Tag is string tag)
        {
            NavigateToTag(tag, updateSelector: false);
        }
    }

    private void OnNavigateRequested(string tag)
    {
        DispatcherQueue.TryEnqueue(() => NavigateToTag(tag, updateSelector: true));
    }

    private void NavigateToTag(string tag, bool updateSelector)
    {
        if (updateSelector)
        {
            _suppressNavEvent = true;
            NavView.SelectedItem = tag switch
            {
                "compare" => NavCompare,
                "jobs" => NavJobs,
                _ => NavWorkbench
            };
            _suppressNavEvent = false;
        }

        Type targetType = tag switch
        {
            "compare" => typeof(ComparePage),
            "jobs" => typeof(JobsPage),
            "settings" => typeof(SettingsPage),
            _ => typeof(WorkbenchPage)
        };

        if (ContentFrame.CurrentSourcePageType != targetType)
        {
            ContentFrame.Navigate(targetType);
        }
    }

    private void OnBannerRequested(string title, string message, InfoBarSeverity severity)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            GlobalInfoBar.Title = title;
            GlobalInfoBar.Message = message;
            GlobalInfoBar.Severity = severity;
            GlobalInfoBar.IsOpen = true;
        });
    }

    private void OnThemeChanged(ElementTheme theme)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            RootGrid.RequestedTheme = theme;
        });
    }

    private void OnCoordinatorStateChanged()
    {
        DispatcherQueue.TryEnqueue(RefreshChromeMetrics);
    }

    private void RefreshChromeMetrics()
    {
        var jobs = App.State.Coordinator.Store.ListJobs(50);
        long totalSaved = jobs.Sum(j => j.Stats.SavedBytes);
        FooterSavedText.Text = ByteFormat.Format(totalSaved);

        var running = jobs.FirstOrDefault(j => j.Status == JobStatus.Running);
        if (running is not null)
        {
            LiveSpeedPill.Visibility = Visibility.Visible;
            string speed = App.State.Coordinator.BytesPerSecond > 1024
                ? $"{ByteFormat.Format((long)App.State.Coordinator.BytesPerSecond)}/s · "
                : string.Empty;
            LiveSpeedText.Text = $"{speed}{running.Stats.CompletedFiles:N0}/{running.Stats.TotalFiles:N0} ({running.Stats.ProgressPercent:F0}%)";

            JobsInfoBadge.Visibility = Visibility.Visible;
            JobsInfoBadge.Value = Math.Max(1, running.Stats.Pending + running.Stats.Processing);
        }
        else
        {
            LiveSpeedPill.Visibility = Visibility.Collapsed;
            if (jobs.Count > 0)
            {
                JobsInfoBadge.Visibility = Visibility.Visible;
                JobsInfoBadge.Value = jobs.Count;
            }
            else
            {
                JobsInfoBadge.Visibility = Visibility.Collapsed;
            }
        }
    }

    private void RootGrid_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "导入到 PDF Resize";
            DropOverlay.Visibility = Visibility.Visible;
        }
    }

    private void RootGrid_DragLeave(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
    }

    private async void RootGrid_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (!e.DataView.Contains(StandardDataFormats.StorageItems))
            return;

        try
        {
            IReadOnlyList<IStorageItem> items = await e.DataView.GetStorageItemsAsync();
            var paths = items
                .Select(i => i.Path)
                .Where(p => !string.IsNullOrWhiteSpace(p))
                .ToList();

            int added = App.State.AddSources(paths);
            if (added > 0)
            {
                NavigateToTag("workbench", updateSelector: true);
                App.State.ShowBanner("已导入路径", $"成功添加 {added} 个文件夹或 PDF 文件，正在扫描体积明细…", InfoBarSeverity.Success);
            }
            else
            {
                App.State.ShowBanner("未发现新路径", "拖入的文件夹或 PDF 已在待处理列表中，或不包含有效 PDF。", InfoBarSeverity.Warning);
            }
        }
        catch (Exception ex)
        {
            App.State.ShowBanner("拖拽导入失败", ex.Message, InfoBarSeverity.Error);
        }
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        App.State.NavigateRequested -= OnNavigateRequested;
        App.State.BannerRequested -= OnBannerRequested;
        App.State.ThemeChanged -= OnThemeChanged;
        App.State.Coordinator.StateChanged -= OnCoordinatorStateChanged;
        App.State.Dispose();
    }
}
