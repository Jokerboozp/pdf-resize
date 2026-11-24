using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PDFResize.App.Interop;

namespace PDFResize.App.Views;

public sealed partial class SettingsPage : Page
{
    private bool _initializing;

    public SettingsPage()
    {
        InitializeComponent();
        DefaultWorkersBox.Maximum = Math.Max(2, Environment.ProcessorCount);
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _initializing = true;
        try
        {
            ThemeCombo.SelectedIndex = App.State.ThemePreference switch
            {
                ElementTheme.Light => 1,
                ElementTheme.Dark => 2,
                _ => 0
            };

            DefaultWorkersBox.Value = App.State.Config.Workers;
            RefreshStorageInfo();
        }
        finally
        {
            _initializing = false;
        }
    }

    private void RefreshStorageInfo()
    {
        int fpCount = App.State.Coordinator.Store.GetAllFingerprints().Count;
        FingerprintCountText.Text = $"当前已记录 {fpCount:N0} 个已优化 PDF 指纹（再次扫描同一目录时将毫秒级跳过）";
        DbPathLabel.Text = $"数据库位置：{App.State.Coordinator.Store.DbPath}";
    }

    private void ThemeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return;
        if (ThemeCombo.SelectedItem is ComboBoxItem { Tag: string tag } &&
            Enum.TryParse<ElementTheme>(tag, out var theme))
        {
            App.State.SetTheme(theme);
        }
    }

    private void DefaultWorkersBox_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_initializing || double.IsNaN(args.NewValue)) return;
        App.State.Config.Workers = Math.Clamp((int)Math.Round(args.NewValue), 1, Environment.ProcessorCount);
        App.State.NotifyConfigChanged();
    }

    private void OpenDbDir_Click(object sender, RoutedEventArgs e)
    {
        string? dir = Path.GetDirectoryName(App.State.Coordinator.Store.DbPath);
        if (!string.IsNullOrWhiteSpace(dir))
            NativeFolderPicker.RevealInExplorer(dir);
    }

    private void ClearFingerprints_Click(object sender, RoutedEventArgs e)
    {
        int cleared = App.State.Coordinator.Store.ClearFingerprints();
        RefreshStorageInfo();
        App.State.ShowBanner(
            "已重置跳过缓存",
            $"已清除 {cleared:N0} 条历史优化指纹记录，后续批量任务将重新扫描并评估所有 PDF。",
            InfoBarSeverity.Success);
    }
}
