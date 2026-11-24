using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PDFResize.App.Interop;
using PDFResize.Core.Models;

namespace PDFResize.App.Views;

public sealed partial class JobsPage : Page
{
    private string _statusFilter = "all";
    private string _searchQuery = string.Empty;
    private bool _suppressComboSelection;
    private long _lastUiUpdateMs;
    private int _refreshScheduled;

    public JobsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        App.State.Coordinator.StateChanged += OnCoordinatorStateChanged;
        HighlightFilterButton(_statusFilter);
        RefreshAll(forceFileList: true);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        App.State.Coordinator.StateChanged -= OnCoordinatorStateChanged;
    }

    private void OnCoordinatorStateChanged()
    {
        long now = Environment.TickCount64;
        if (now - _lastUiUpdateMs < 240)
        {
            if (Interlocked.Exchange(ref _refreshScheduled, 1) == 0)
            {
                _ = Task.Delay(250).ContinueWith(_ =>
                {
                    Interlocked.Exchange(ref _refreshScheduled, 0);
                    DispatcherQueue.TryEnqueue(() => RefreshAll(forceFileList: true));
                });
            }
            return;
        }

        _lastUiUpdateMs = now;
        DispatcherQueue.TryEnqueue(() => RefreshAll(forceFileList: true));
    }

    private void RefreshAll(bool forceFileList)
    {
        var jobs = App.State.Coordinator.Store.ListJobs(60);

        _suppressComboSelection = true;
        try
        {
            JobSelectorCombo.Items.Clear();
            foreach (var j in jobs)
            {
                JobSelectorCombo.Items.Add(new ComboBoxItem
                {
                    Content = $"[{j.StatusDisplay}] {j.Name} · {j.SubtitleDisplay}",
                    Tag = j.Id
                });
            }

            if (jobs.Count == 0)
            {
                App.State.SelectedJobId = null;
                RenderEmptyJobState();
                return;
            }

            string targetId = App.State.SelectedJobId is not null && jobs.Any(j => j.Id == App.State.SelectedJobId)
                ? App.State.SelectedJobId
                : jobs[0].Id;

            App.State.SelectedJobId = targetId;
            for (int i = 0; i < JobSelectorCombo.Items.Count; i++)
            {
                if (JobSelectorCombo.Items[i] is ComboBoxItem { Tag: string id } && id == targetId)
                {
                    JobSelectorCombo.SelectedIndex = i;
                    break;
                }
            }
        }
        finally
        {
            _suppressComboSelection = false;
        }

        if (App.State.SelectedJobId is { } selectedId &&
            App.State.Coordinator.Store.GetJob(selectedId) is { } job)
        {
            RenderJobDetails(job, forceFileList);
        }
    }

    private void RenderEmptyJobState()
    {
        JobStatusText.Text = "暂无任务";
        JobProgressBar.Value = 0;
        ProgressSummaryText.Text = "可在「批量压缩」页添加文件夹并启动任务";
        ActiveFilesText.Text = string.Empty;

        PauseJobBtn.Visibility = Visibility.Collapsed;
        ResumeJobBtn.Visibility = Visibility.Collapsed;
        RetryFailedBtn.Visibility = Visibility.Collapsed;
        CancelJobBtn.Visibility = Visibility.Collapsed;
        DeleteJobBtn.IsEnabled = false;

        KpiSavedBytesText.Text = "0 B";
        KpiSavedPctText.Text = "平均压缩率 0.0%";
        KpiVolumePairText.Text = "0 B → 0 B";
        KpiTotalOrigText.Text = "批次总计 0 B";
        KpiSpeedText.Text = "—";
        KpiEtaText.Text = "预计剩余：—";
        KpiCountsMainText.Text = "0 / 0";
        KpiCountsSubText.Text = "已优化 0 · 跳过 0 · 失败 0";

        FilesListView.ItemsSource = null;
        EmptyRowsHintText.Visibility = Visibility.Visible;
    }

    private void RenderJobDetails(JobRecord job, bool reloadRows)
    {
        var st = job.Stats;
        bool active = App.State.Coordinator.IsJobActive(job.Id) || job.Status == JobStatus.Running;

        JobStatusText.Text = job.StatusDisplay;
        JobProgressBar.Value = st.ProgressPercent;
        ProgressSummaryText.Text = $"已完成 {st.CompletedFiles:N0} / {st.TotalFiles:N0} 个文件 ({st.ProgressPercent:F1}%) · 档位：{CompressionConfig.PresetTitle(job.Config.Preset)}";

        if (active && App.State.Coordinator.ActiveFiles.Count > 0)
        {
            ActiveFilesText.Text = $"正在处理：{string.Join(" , ", App.State.Coordinator.ActiveFiles)}";
        }
        else
        {
            ActiveFilesText.Text = string.Empty;
        }

        PauseJobBtn.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        ResumeJobBtn.Visibility = (!active && st.Pending > 0 && job.Status is JobStatus.Paused or JobStatus.Created or JobStatus.Failed)
            ? Visibility.Visible
            : Visibility.Collapsed;
        RetryFailedBtn.Visibility = (!active && st.Failed > 0) ? Visibility.Visible : Visibility.Collapsed;
        CancelJobBtn.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        DeleteJobBtn.IsEnabled = !active;

        KpiSavedBytesText.Text = ByteFormat.Format(st.SavedBytes);
        KpiSavedPctText.Text = $"平均缩减 {st.SavingPercent:F1}% · 优化位图 {st.ImagesOptimized:N0} 张";
        KpiVolumePairText.Text = $"{ByteFormat.Format(st.ProcessedOriginalBytes)} → {ByteFormat.Format(st.ProcessedNewBytes)}";
        KpiTotalOrigText.Text = $"批次原始总计 {ByteFormat.Format(st.TotalOriginalBytes)}";

        if (active && App.State.Coordinator.BytesPerSecond > 1024)
        {
            KpiSpeedText.Text = $"{ByteFormat.Format((long)App.State.Coordinator.BytesPerSecond)} / s";
            KpiEtaText.Text = $"预计剩余：{ByteFormat.FormatEta(App.State.Coordinator.EtaSeconds)}";
        }
        else
        {
            KpiSpeedText.Text = active ? "预热子进程…" : "已就绪";
            KpiEtaText.Text = active ? "正在统计吞吐…" : (job.Status == JobStatus.Completed ? "全部处理完毕" : "已停止");
        }

        KpiCountsMainText.Text = $"{st.CompletedFiles:N0} / {st.TotalFiles:N0}";
        KpiCountsSubText.Text = $"已优化 {st.Done:N0} · 跳过 {st.Skipped:N0} · 失败 {st.Failed:N0}";

        if (reloadRows)
        {
            var rows = App.State.Coordinator.Store.ListJobFiles(job.Id, _statusFilter, _searchQuery, limit: 5000);
            FilesListView.ItemsSource = rows;
            EmptyRowsHintText.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void HighlightFilterButton(string filter)
    {
        Button[] all = [FilterAllBtn, FilterDoneBtn, FilterSkippedBtn, FilterFailedBtn, FilterPendingBtn];
        foreach (var btn in all)
        {
            bool match = (btn.Tag as string) == filter;
            btn.BorderThickness = match ? new Thickness(2) : new Thickness(1);
            string key = match ? "AccentFillColorDefaultBrush" : "CardStrokeColorDefaultBrush";
            if (Application.Current.Resources.TryGetValue(key, out object? val) && val is Microsoft.UI.Xaml.Media.Brush br)
                btn.BorderBrush = br;
        }
    }

    private void JobSelectorCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressComboSelection) return;
        if (JobSelectorCombo.SelectedItem is ComboBoxItem { Tag: string id })
        {
            App.State.SelectedJobId = id;
            RefreshAll(forceFileList: true);
        }
    }

    private void StatusFilter_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string f }) return;
        _statusFilter = f;
        HighlightFilterButton(f);
        RefreshAll(forceFileList: true);
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _searchQuery = SearchBox.Text.Trim();
        RefreshAll(forceFileList: true);
    }

    private void PauseJob_Click(object sender, RoutedEventArgs e)
    {
        if (App.State.SelectedJobId is { } id)
            App.State.Coordinator.PauseJob(id);
    }

    private void ResumeJob_Click(object sender, RoutedEventArgs e)
    {
        if (App.State.SelectedJobId is { } id)
            App.State.Coordinator.StartJob(id);
    }

    private void RetryFailed_Click(object sender, RoutedEventArgs e)
    {
        if (App.State.SelectedJobId is { } id)
        {
            int count = App.State.Coordinator.RetryFailed(id);
            App.State.ShowBanner("重试失败文件", $"已重新加入 {count} 个失败文件并启动压缩。", InfoBarSeverity.Informational);
        }
    }

    private void CancelJob_Click(object sender, RoutedEventArgs e)
    {
        if (App.State.SelectedJobId is { } id)
            App.State.Coordinator.CancelJob(id);
    }

    private void DeleteJob_Click(object sender, RoutedEventArgs e)
    {
        if (App.State.SelectedJobId is { } id)
        {
            App.State.Coordinator.DeleteJob(id);
            App.State.SelectedJobId = null;
            RefreshAll(forceFileList: true);
        }
    }

    private void RevealRowFile_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string path })
            NativeFolderPicker.RevealInExplorer(path);
    }

    private void CompareRowFile_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string path })
            App.State.OpenInCompare(path);
    }

    private void NewJobFromWorkbench_Click(object sender, RoutedEventArgs e)
    {
        if (Frame.CanGoBack)
            Frame.Navigate(typeof(WorkbenchPage));
        else
            Frame.Navigate(typeof(WorkbenchPage));
    }
}
