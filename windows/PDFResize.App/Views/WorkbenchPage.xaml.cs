using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PDFResize.App.Interop;
using PDFResize.Core.Engine;
using PDFResize.Core.Models;

namespace PDFResize.App.Views;

public sealed partial class WorkbenchPage : Page
{
    private bool _updatingControls = true;
    private int _scanVersion;

    public WorkbenchPage()
    {
        _updatingControls = true;
        InitializeComponent();
        WorkersBox.Maximum = Math.Max(2, Environment.ProcessorCount);
        _updatingControls = false;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        App.State.SourcesChanged += OnSourcesChanged;
        App.State.ConfigChanged += SyncControlsFromState;

        SyncControlsFromState();
        if (App.State.SourcePaths.Count > 0 && App.State.LatestScan is null)
        {
            _ = RunScanAsync();
        }
        else
        {
            RenderScanState(App.State.LatestScan);
        }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        App.State.SourcesChanged -= OnSourcesChanged;
        App.State.ConfigChanged -= SyncControlsFromState;
    }

    private void OnSourcesChanged()
    {
        DispatcherQueue.TryEnqueue(() => _ = RunScanAsync());
    }

    private void SyncControlsFromState()
    {
        _updatingControls = true;
        try
        {
            var cfg = App.State.Config;
            RecursiveCheck.IsChecked = App.State.RecursiveScan;

            ActivePresetBadge.Text = $"当前：{CompressionConfig.PresetTitle(cfg.Preset)}";
            HighlightPresetButton(cfg.Preset);

            bool imageEnabled = cfg.Preset != CompressionPreset.Lossless && cfg.CompressImages;
            DpiSlider.IsEnabled = imageEnabled;
            QualitySlider.IsEnabled = imageEnabled;
            DpiSlider.Value = Math.Clamp(cfg.TargetDpi, 72, 300);
            QualitySlider.Value = Math.Clamp(cfg.JpegQuality, 25, 95);
            DpiValueLabel.Text = imageEnabled ? $"{cfg.TargetDpi} DPI" : "不重采样（无损）";
            QualityValueLabel.Text = imageEnabled ? $"{cfg.JpegQuality}%" : "原图直通";

            GrayscaleToggle.IsOn = cfg.Grayscale;
            StripMetadataToggle.IsOn = cfg.StripMetadata;
            PreserveMtimeToggle.IsOn = cfg.PreserveModificationDate;
            SkipOptimizedToggle.IsOn = cfg.SkipAlreadyOptimized;

            MinSavingBox.Value = cfg.MinSavingPercent;
            SkipSmallBox.Value = cfg.SkipSmallerThanKb;
            WorkersBox.Value = cfg.Workers;

            bool inplace = App.State.OutputMode == OutputMode.Inplace;
            InplaceRadio.IsChecked = inplace;
            OutDirRadio.IsChecked = !inplace;
            BackupDirRow.Visibility = inplace ? Visibility.Visible : Visibility.Collapsed;
            OutputDirRow.Visibility = inplace ? Visibility.Collapsed : Visibility.Visible;

            BackupDirTextBox.Text = App.State.BackupDirectory;
            OutputDirTextBox.Text = App.State.OutputDirectory;

            HighlightTrialButton(App.State.TrialLimitFiles ?? 0);
            UpdateStartButtonCaption();
        }
        finally
        {
            _updatingControls = false;
        }
    }

    private static Microsoft.UI.Xaml.Media.Brush? LookupBrush(string key) =>
        Application.Current.Resources.TryGetValue(key, out object? val) ? val as Microsoft.UI.Xaml.Media.Brush : null;

    private void HighlightPresetButton(CompressionPreset preset)
    {
        Button[] all = [PresetLosslessBtn, PresetLightBtn, PresetBalancedBtn, PresetExtremeBtn];
        foreach (var btn in all)
        {
            bool match = btn.Tag is string s && s == preset.ToString();
            btn.BorderThickness = match ? new Thickness(2) : new Thickness(1);
            if (LookupBrush(match ? "AccentFillColorDefaultBrush" : "CardStrokeColorDefaultBrush") is { } br)
                btn.BorderBrush = br;
        }
    }

    private void HighlightTrialButton(int limit)
    {
        Button[] all = [LimitAllBtn, Limit5Btn, Limit10Btn, Limit50Btn];
        foreach (var btn in all)
        {
            bool match = int.TryParse(btn.Tag as string, out int v) && v == limit;
            btn.BorderThickness = match ? new Thickness(2) : new Thickness(1);
            if (LookupBrush(match ? "AccentFillColorDefaultBrush" : "CardStrokeColorDefaultBrush") is { } br)
                btn.BorderBrush = br;
        }
    }

    private void UpdateStartButtonCaption()
    {
        string verb = App.State.OutputMode == OutputMode.Inplace ? "开始原地优化" : "开始批量导出";
        if (App.State.TrialLimitFiles is > 0)
        {
            StartBatchBtnText.Text = $"{verb}（试跑前 {App.State.TrialLimitFiles.Value} 个）";
        }
        else if (App.State.LatestScan is { PendingCount: > 0 } scan)
        {
            StartBatchBtnText.Text = $"{verb} ({scan.PendingCount:N0} 个 PDF)";
        }
        else
        {
            StartBatchBtnText.Text = verb;
        }
    }

    private async Task RunScanAsync()
    {
        int ticket = ++_scanVersion;
        if (App.State.SourcePaths.Count == 0)
        {
            App.State.LatestScan = null;
            RenderScanState(null);
            return;
        }

        ScanSpinner.Visibility = Visibility.Visible;
        ScanSpinner.IsActive = true;

        var paths = App.State.SourcePaths.ToList();
        bool recursive = App.State.RecursiveScan;
        int skipKb = App.State.Config.SkipSmallerThanKb;
        bool checkFp = App.State.Config.SkipAlreadyOptimized && App.State.OutputMode == OutputMode.Inplace;
        var excludes = new List<string>();
        if (!string.IsNullOrWhiteSpace(App.State.OutputDirectory)) excludes.Add(App.State.OutputDirectory);
        if (!string.IsNullOrWhiteSpace(App.State.BackupDirectory)) excludes.Add(App.State.BackupDirectory);

        try
        {
            var summary = await Task.Run(() =>
            {
                var fps = checkFp ? App.State.Coordinator.Store.GetAllFingerprints() : null;
                return DirectoryScanner.Scan(
                    paths,
                    recursive: recursive,
                    skipSmallerThanKb: skipKb,
                    fingerprints: fps,
                    limitFiles: null,
                    excludeDirectories: excludes);
            });

            if (ticket != _scanVersion) return;
            App.State.LatestScan = summary;
            if (summary.LargestSamples.Count > 0 && string.IsNullOrWhiteSpace(App.State.ComparePdfPath))
            {
                App.State.ComparePdfPath = summary.LargestSamples[0].SourcePath;
            }
            RenderScanState(summary);
        }
        catch (Exception ex)
        {
            if (ticket == _scanVersion)
            {
                App.State.ShowBanner("目录扫描异常", ex.Message, InfoBarSeverity.Error);
            }
        }
        finally
        {
            if (ticket == _scanVersion)
            {
                ScanSpinner.IsActive = false;
                ScanSpinner.Visibility = Visibility.Collapsed;
            }
        }
    }

    private void RenderScanState(ScanSummary? summary)
    {
        bool hasSources = App.State.SourcePaths.Count > 0;
        EmptySourcesHint.Visibility = hasSources ? Visibility.Collapsed : Visibility.Visible;
        SourcesItemsControl.Visibility = hasSources ? Visibility.Visible : Visibility.Collapsed;
        ClearSourcesBtn.IsEnabled = hasSources;

        if (!hasSources || summary is null)
        {
            SourcesItemsControl.ItemsSource = null;
            ScanMetricsPanel.Visibility = Visibility.Collapsed;
            UpdateStartButtonCaption();
            return;
        }

        SourcesItemsControl.ItemsSource = summary.Sources;
        ScanMetricsPanel.Visibility = Visibility.Visible;
        KpiTotalFiles.Text = $"{summary.TotalFiles:N0}";
        KpiTotalBytes.Text = ByteFormat.Format(summary.TotalBytes);
        KpiPendingFiles.Text = $"{summary.PendingCount:N0}";
        KpiSkippedFiles.Text = $"{summary.AlreadyOptimizedCount:N0}";

        SamplePdfCombo.Items.Clear();
        foreach (var sample in summary.LargestSamples)
        {
            SamplePdfCombo.Items.Add(new ComboBoxItem
            {
                Content = $"{sample.RelativePath} ({ByteFormat.Format(sample.OriginalSize)})",
                Tag = sample.SourcePath
            });
        }
        if (SamplePdfCombo.Items.Count > 0)
            SamplePdfCombo.SelectedIndex = 0;

        UpdateStartButtonCaption();
    }

    private async void PickFolders_Click(object sender, RoutedEventArgs e)
    {
        if (App.MainWindowInstance is null) return;
        var picked = await NativeFolderPicker.PickMultipleFoldersAsync(App.MainWindowInstance);
        if (picked.Count > 0)
        {
            App.State.AddSources(picked);
        }
    }

    private async void PickFiles_Click(object sender, RoutedEventArgs e)
    {
        if (App.MainWindowInstance is null) return;
        var picked = await NativeFolderPicker.PickPdfFilesAsync(App.MainWindowInstance, allowMultiple: true);
        if (picked.Count > 0)
        {
            App.State.AddSources(picked);
        }
    }

    private void Rescan_Click(object sender, RoutedEventArgs e) => _ = RunScanAsync();

    private void ClearSources_Click(object sender, RoutedEventArgs e) => App.State.ClearSources();

    private void RecursiveCheck_Click(object sender, RoutedEventArgs e)
    {
        if (_updatingControls) return;
        App.State.RecursiveScan = RecursiveCheck.IsChecked == true;
        _ = RunScanAsync();
    }

    private void RevealSource_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string path })
            NativeFolderPicker.RevealInExplorer(path);
    }

    private void RemoveSource_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string path })
            App.State.RemoveSource(path);
    }

    private void OpenSelectedSampleInCompare_Click(object sender, RoutedEventArgs e)
    {
        if (SamplePdfCombo.SelectedItem is ComboBoxItem { Tag: string path })
        {
            App.State.OpenInCompare(path);
        }
    }

    private void PresetBtn_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string tag } || !Enum.TryParse<CompressionPreset>(tag, out var preset))
            return;

        int workers = App.State.Config.Workers;
        bool skipOpt = App.State.Config.SkipAlreadyOptimized;
        bool keepTime = App.State.Config.PreserveModificationDate;
        int skipKb = App.State.Config.SkipSmallerThanKb;

        var next = CompressionConfig.ForPreset(preset, workers);
        next.SkipAlreadyOptimized = skipOpt;
        next.PreserveModificationDate = keepTime;
        next.SkipSmallerThanKb = skipKb;

        App.State.Config = next;
        SyncControlsFromState();
    }

    private void DpiSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (!IsLoaded || _updatingControls) return;
        App.State.Config.TargetDpi = (int)Math.Round(e.NewValue);
        App.State.Config.Preset = CompressionPreset.Custom;
        App.State.Config.CompressImages = true;
        App.State.Config.DownsampleImages = true;
        DpiValueLabel.Text = $"{App.State.Config.TargetDpi} DPI";
        ActivePresetBadge.Text = "当前：自定义参数";
        HighlightPresetButton(CompressionPreset.Custom);
    }

    private void QualitySlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (!IsLoaded || _updatingControls) return;
        App.State.Config.JpegQuality = (int)Math.Round(e.NewValue);
        App.State.Config.Preset = CompressionPreset.Custom;
        App.State.Config.CompressImages = true;
        QualityValueLabel.Text = $"{App.State.Config.JpegQuality}%";
        ActivePresetBadge.Text = "当前：自定义参数";
        HighlightPresetButton(CompressionPreset.Custom);
    }

    private void AdvancedToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded || _updatingControls) return;
        bool prevSkip = App.State.Config.SkipAlreadyOptimized;

        App.State.Config.Grayscale = GrayscaleToggle.IsOn;
        App.State.Config.StripMetadata = StripMetadataToggle.IsOn;
        App.State.Config.PreserveModificationDate = PreserveMtimeToggle.IsOn;
        App.State.Config.SkipAlreadyOptimized = SkipOptimizedToggle.IsOn;

        if (prevSkip != App.State.Config.SkipAlreadyOptimized)
            _ = RunScanAsync();
    }

    private void AdvancedNumber_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!IsLoaded || _updatingControls || double.IsNaN(args.NewValue)) return;

        if (ReferenceEquals(sender, MinSavingBox))
        {
            App.State.Config.MinSavingPercent = Math.Clamp(args.NewValue, 0, 50);
        }
        else if (ReferenceEquals(sender, SkipSmallBox))
        {
            App.State.Config.SkipSmallerThanKb = Math.Max(0, (int)Math.Round(args.NewValue));
            _ = RunScanAsync();
        }
        else if (ReferenceEquals(sender, WorkersBox))
        {
            App.State.Config.Workers = Math.Clamp((int)Math.Round(args.NewValue), 1, Environment.ProcessorCount);
        }
    }

    private void OutputModeRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded || _updatingControls) return;
        App.State.OutputMode = InplaceRadio.IsChecked == true ? OutputMode.Inplace : OutputMode.OutputDirectory;
        BackupDirRow.Visibility = App.State.OutputMode == OutputMode.Inplace ? Visibility.Visible : Visibility.Collapsed;
        OutputDirRow.Visibility = App.State.OutputMode == OutputMode.OutputDirectory ? Visibility.Visible : Visibility.Collapsed;
        UpdateStartButtonCaption();
        _ = RunScanAsync();
    }

    private void BackupDirTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!IsLoaded || _updatingControls) return;
        App.State.BackupDirectory = BackupDirTextBox.Text.Trim();
    }

    private void OutputDirTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!IsLoaded || _updatingControls) return;
        App.State.OutputDirectory = OutputDirTextBox.Text.Trim();
    }

    private async void PickBackupDir_Click(object sender, RoutedEventArgs e)
    {
        if (App.MainWindowInstance is null) return;
        string? folder = await NativeFolderPicker.PickSingleFolderAsync(App.MainWindowInstance);
        if (!string.IsNullOrWhiteSpace(folder))
        {
            BackupDirTextBox.Text = folder;
            App.State.BackupDirectory = folder;
            _ = RunScanAsync();
        }
    }

    private void ClearBackupDir_Click(object sender, RoutedEventArgs e)
    {
        BackupDirTextBox.Text = string.Empty;
        App.State.BackupDirectory = string.Empty;
        _ = RunScanAsync();
    }

    private async void PickOutputDir_Click(object sender, RoutedEventArgs e)
    {
        if (App.MainWindowInstance is null) return;
        string? folder = await NativeFolderPicker.PickSingleFolderAsync(App.MainWindowInstance);
        if (!string.IsNullOrWhiteSpace(folder))
        {
            OutputDirTextBox.Text = folder;
            App.State.OutputDirectory = folder;
            _ = RunScanAsync();
        }
    }

    private void TrialLimit_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string s } || !int.TryParse(s, out int v))
            return;
        App.State.TrialLimitFiles = v > 0 ? v : null;
        HighlightTrialButton(v);
        UpdateStartButtonCaption();
    }

    private void GoCompare_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(App.State.ComparePdfPath) && File.Exists(App.State.ComparePdfPath))
        {
            App.State.OpenInCompare(App.State.ComparePdfPath);
        }
        else if (SamplePdfCombo.SelectedItem is ComboBoxItem { Tag: string sample })
        {
            App.State.OpenInCompare(sample);
        }
        else
        {
            App.State.OpenJobMonitor(App.State.SelectedJobId ?? string.Empty);
            App.State.ShowBanner("请选择对比文件", "您可以在画质对比页点击「选择 PDF 文件…」载入任意文档。", InfoBarSeverity.Informational);
            if (App.MainWindowInstance is not null)
                App.State.OpenInCompare(App.State.ComparePdfPath ?? string.Empty);
        }
    }

    private async void StartBatch_Click(object sender, RoutedEventArgs e)
    {
        if (App.State.SourcePaths.Count == 0)
        {
            App.State.ShowBanner("尚未添加文件夹", "请先点击「选择多个文件夹…」或将文件夹拖入窗口。", InfoBarSeverity.Warning);
            return;
        }

        if (App.State.OutputMode == OutputMode.OutputDirectory && string.IsNullOrWhiteSpace(App.State.OutputDirectory))
        {
            App.State.ShowBanner("缺少导出目录", "选择「另存到新文件夹」时，请先指定导出目标目录。", InfoBarSeverity.Warning);
            return;
        }

        StartBatchBtn.IsEnabled = false;
        try
        {
            var sources = App.State.SourcePaths.ToList();
            var mode = App.State.OutputMode;
            string? outDir = string.IsNullOrWhiteSpace(App.State.OutputDirectory) ? null : App.State.OutputDirectory;
            string? bkpDir = string.IsNullOrWhiteSpace(App.State.BackupDirectory) ? null : App.State.BackupDirectory;
            var cfg = App.State.Config.Clone();
            bool recursive = App.State.RecursiveScan;
            int? limit = App.State.TrialLimitFiles;

            var job = await Task.Run(() => App.State.Coordinator.CreateAndStartLocalJob(
                sources,
                mode,
                outDir,
                bkpDir,
                cfg,
                recursive: recursive,
                limitFiles: limit,
                autoStart: true));

            App.State.OpenJobMonitor(job.Id);
        }
        catch (Exception ex)
        {
            App.State.ShowBanner("无法启动任务", ex.Message, InfoBarSeverity.Error);
        }
        finally
        {
            StartBatchBtn.IsEnabled = true;
        }
    }
}
