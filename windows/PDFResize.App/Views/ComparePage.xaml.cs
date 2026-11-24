using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using PDFResize.App.Interop;
using PDFResize.Core.Engine;
using PDFResize.Core.Models;
using Windows.Data.Pdf;
using Windows.Foundation;
using Windows.Storage;
using Windows.Storage.Streams;

namespace PDFResize.App.Views;

public sealed partial class ComparePage : Page
{
    private CompressionConfig _previewConfig = App.State.Config.Clone();
    private string? _sourcePath;
    private string? _compressedTempPath;
    private PdfDocument? _origPdf;
    private PdfDocument? _compPdf;
    private uint _pageCount;
    private uint _currentPageIndex;
    private double _curtainRatio = 0.5;
    private double _zoomMultiplier = 0.0; // 0 = fit width
    private bool _draggingCurtain;
    private bool _syncingScroll;
    private int _previewGeneration;

    public ComparePage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _previewConfig = App.State.Config.Clone();
        HighlightComparePreset(_previewConfig.Preset);

        if (!string.IsNullOrWhiteSpace(App.State.ComparePdfPath) && File.Exists(App.State.ComparePdfPath))
        {
            _ = LoadAndCompressPreviewAsync(App.State.ComparePdfPath, resetPage: true);
        }
    }

    private void HighlightComparePreset(CompressionPreset preset)
    {
        Button[] btns = [CmpLosslessBtn, CmpLightBtn, CmpBalancedBtn, CmpExtremeBtn];
        foreach (var b in btns)
        {
            bool match = b.Tag is string s && s == preset.ToString();
            b.BorderThickness = match ? new Thickness(2) : new Thickness(1);
            string key = match ? "AccentFillColorDefaultBrush" : "CardStrokeColorDefaultBrush";
            if (Application.Current.Resources.TryGetValue(key, out object? val) && val is Microsoft.UI.Xaml.Media.Brush br)
                b.BorderBrush = br;
        }
    }

    private async void PickPdf_Click(object sender, RoutedEventArgs e)
    {
        if (App.MainWindowInstance is null) return;
        var files = await NativeFolderPicker.PickPdfFilesAsync(App.MainWindowInstance, allowMultiple: false);
        if (files.Count > 0)
        {
            App.State.ComparePdfPath = files[0];
            await LoadAndCompressPreviewAsync(files[0], resetPage: true);
        }
    }

    private async void ComparePreset_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string tag } || !Enum.TryParse<CompressionPreset>(tag, out var preset))
            return;

        _previewConfig = CompressionConfig.ForPreset(preset, App.State.Config.Workers);
        HighlightComparePreset(preset);
        if (!string.IsNullOrWhiteSpace(_sourcePath) && File.Exists(_sourcePath))
        {
            await LoadAndCompressPreviewAsync(_sourcePath, resetPage: false);
        }
    }

    private void ApplyPresetToWorkbench_Click(object sender, RoutedEventArgs e)
    {
        App.State.Config = _previewConfig.Clone();
        App.State.NotifyConfigChanged();
        App.State.ShowBanner(
            "已同步压缩参数",
            $"已将「{CompressionConfig.PresetTitle(_previewConfig.Preset)}」参数同步到批量压缩工作台。",
            InfoBarSeverity.Success);
    }

    private async Task LoadAndCompressPreviewAsync(string pdfPath, bool resetPage)
    {
        int gen = ++_previewGeneration;
        _sourcePath = Path.GetFullPath(pdfPath);
        FileNameText.Text = Path.GetFileName(_sourcePath);
        FilePathText.Text = _sourcePath;

        PreviewBusyRing.Visibility = Visibility.Visible;
        PreviewBusyRing.IsActive = true;

        try
        {
            var cfgSnapshot = _previewConfig.Clone();
            var (previewPath, res) = await Task.Run(() => PdfCompressor.GeneratePreviewCopy(_sourcePath, cfgSnapshot));
            if (gen != _previewGeneration) return;

            _compressedTempPath = previewPath;
            long origBytes = new FileInfo(_sourcePath).Length;
            long compBytes = new FileInfo(previewPath).Length;
            long saved = Math.Max(0, origBytes - compBytes);
            double pct = origBytes > 0 ? (double)saved / origBytes * 100.0 : 0.0;

            OrigSizeLabel.Text = ByteFormat.Format(origBytes);
            CompSizeLabel.Text = ByteFormat.Format(compBytes);
            SavedRatioLabel.Text = saved > 0
                ? $"{ByteFormat.Format(saved)} (-{pct:F1}%)"
                : "0 B（原文件已是最优）";
            MetaStatsLabel.Text = $"档位：{CompressionConfig.PresetTitle(cfgSnapshot.Preset)} · 重编码位图 {res.ImagesOptimized} 张 · 耗时 {res.DurationMs} ms";

            StorageFile origFile = await StorageFile.GetFileFromPathAsync(_sourcePath);
            StorageFile compFile = await StorageFile.GetFileFromPathAsync(previewPath);
            _origPdf = await PdfDocument.LoadFromFileAsync(origFile);
            _compPdf = await PdfDocument.LoadFromFileAsync(compFile);
            _pageCount = _origPdf.PageCount;

            if (resetPage || _currentPageIndex >= _pageCount)
                _currentPageIndex = 0;

            EmptyComparePanel.Visibility = Visibility.Collapsed;
            UpdateDisplayModeVisibility();
            await RenderCurrentPagePairAsync(gen);
        }
        catch (Exception ex)
        {
            if (gen == _previewGeneration)
            {
                App.State.ShowBanner("无法渲染预览 PDF", ex.Message, InfoBarSeverity.Error);
            }
        }
        finally
        {
            if (gen == _previewGeneration)
            {
                PreviewBusyRing.IsActive = false;
                PreviewBusyRing.Visibility = Visibility.Collapsed;
            }
        }
    }

    private async Task RenderCurrentPagePairAsync(int gen)
    {
        if (_origPdf is null || _compPdf is null || _pageCount == 0)
            return;

        PrevPageBtn.IsEnabled = _currentPageIndex > 0;
        NextPageBtn.IsEnabled = _currentPageIndex + 1 < _pageCount;
        PageIndicatorText.Text = $"第 {_currentPageIndex + 1} / {_pageCount} 页";

        uint compIndex = Math.Min(_currentPageIndex, _compPdf.PageCount - 1);
        using PdfPage origPage = _origPdf.GetPage(_currentPageIndex);
        using PdfPage compPage = _compPdf.GetPage(compIndex);

        // Render at high crisp resolution (2.2x logical points, capped at 2600px width)
        double scaleFactor = _zoomMultiplier > 0 ? _zoomMultiplier * 2.0 : 2.2;
        uint renderWidth = (uint)Math.Clamp(origPage.Size.Width * scaleFactor, 720, 2800);

        BitmapImage origBmp = await RenderPageToBitmapAsync(origPage, renderWidth);
        BitmapImage compBmp = await RenderPageToBitmapAsync(compPage, renderWidth);
        if (gen != _previewGeneration) return;

        CurtainOriginalImage.Source = origBmp;
        CurtainCompressedImage.Source = compBmp;
        SideOriginalImage.Source = origBmp;
        SideCompressedImage.Source = compBmp;

        ApplyImageZoomSizing(origPage.Size.Width);
        UpdateCurtainGeometry();
    }

    private static async Task<BitmapImage> RenderPageToBitmapAsync(PdfPage page, uint destinationWidth)
    {
        using var stream = new InMemoryRandomAccessStream();
        var options = new PdfPageRenderOptions
        {
            DestinationWidth = destinationWidth
        };
        await page.RenderToStreamAsync(stream, options);
        stream.Seek(0);

        var bmp = new BitmapImage();
        await bmp.SetSourceAsync(stream);
        return bmp;
    }

    private void ApplyImageZoomSizing(double pageLogicalWidth)
    {
        if (_zoomMultiplier <= 0)
        {
            double fitW = Math.Max(480, CurtainScrollViewer.ActualWidth > 100 ? CurtainScrollViewer.ActualWidth - 48 : 860);
            CurtainStage.Width = fitW;
            SideOriginalImage.Width = double.NaN;
            SideCompressedImage.Width = double.NaN;
        }
        else
        {
            double targetW = Math.Max(360, pageLogicalWidth * _zoomMultiplier);
            CurtainStage.Width = targetW;
            SideOriginalImage.Width = targetW;
            SideCompressedImage.Width = targetW;
        }
    }

    private void UpdateDisplayModeVisibility()
    {
        if (_origPdf is null) return;
        bool isCurtain = (ModeCombo.SelectedItem as ComboBoxItem)?.Tag as string != "side";
        CurtainScrollViewer.Visibility = isCurtain ? Visibility.Visible : Visibility.Collapsed;
        CurtainSliderPanel.Visibility = isCurtain ? Visibility.Visible : Visibility.Collapsed;
        SideBySideGrid.Visibility = isCurtain ? Visibility.Collapsed : Visibility.Visible;
        UpdateCurtainGeometry();
    }

    private void UpdateCurtainGeometry()
    {
        double w = CurtainStage.ActualWidth;
        double h = CurtainStage.ActualHeight;
        if (w <= 1 || h <= 1) return;

        double splitX = Math.Clamp(w * _curtainRatio, 0, w);
        OriginalClipGeometry.Rect = new Rect(0, 0, splitX, h);

        CurtainDividerLine.Height = h;
        Canvas.SetLeft(CurtainDividerLine, Math.Max(0, splitX - 1.5));
        Canvas.SetTop(CurtainDividerLine, 0);

        Canvas.SetLeft(CurtainHandleThumb, splitX - 17);
        Canvas.SetTop(CurtainHandleThumb, Math.Max(0, h / 2.0 - 17));
    }

    private void CurtainStage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateCurtainGeometry();
    }

    private void CurtainStage_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _draggingCurtain = true;
        CurtainStage.CapturePointer(e.Pointer);
        SetCurtainFromPointer(e.GetCurrentPoint(CurtainStage).Position.X);
    }

    private void CurtainStage_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_draggingCurtain) return;
        SetCurtainFromPointer(e.GetCurrentPoint(CurtainStage).Position.X);
    }

    private void CurtainStage_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_draggingCurtain) return;
        _draggingCurtain = false;
        CurtainStage.ReleasePointerCapture(e.Pointer);
    }

    private void SetCurtainFromPointer(double x)
    {
        double w = CurtainStage.ActualWidth;
        if (w <= 1) return;
        _curtainRatio = Math.Clamp(x / w, 0.0, 1.0);
        CurtainSlider.Value = _curtainRatio * 100.0;
        UpdateCurtainGeometry();
    }

    private void CurtainSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        _curtainRatio = Math.Clamp(e.NewValue / 100.0, 0.0, 1.0);
        UpdateCurtainGeometry();
    }

    private void ModeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        UpdateDisplayModeVisibility();
    }

    private async void ZoomCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        if ((ZoomCombo.SelectedItem as ComboBoxItem)?.Tag is string tag &&
            double.TryParse(tag, System.Globalization.CultureInfo.InvariantCulture, out double z))
        {
            _zoomMultiplier = z;
            if (_origPdf is not null)
            {
                await RenderCurrentPagePairAsync(_previewGeneration);
            }
        }
    }

    private async void PrevPage_Click(object sender, RoutedEventArgs e)
    {
        if (_currentPageIndex > 0)
        {
            _currentPageIndex--;
            await RenderCurrentPagePairAsync(_previewGeneration);
        }
    }

    private async void NextPage_Click(object sender, RoutedEventArgs e)
    {
        if (_currentPageIndex + 1 < _pageCount)
        {
            _currentPageIndex++;
            await RenderCurrentPagePairAsync(_previewGeneration);
        }
    }

    private void LeftSideScroll_ViewChanged(object sender, ScrollViewerViewChangedEventArgs e)
    {
        if (_syncingScroll) return;
        _syncingScroll = true;
        RightSideScroll.ChangeView(LeftSideScroll.HorizontalOffset, LeftSideScroll.VerticalOffset, null, true);
        _syncingScroll = false;
    }

    private void RightSideScroll_ViewChanged(object sender, ScrollViewerViewChangedEventArgs e)
    {
        if (_syncingScroll) return;
        _syncingScroll = true;
        LeftSideScroll.ChangeView(RightSideScroll.HorizontalOffset, RightSideScroll.VerticalOffset, null, true);
        _syncingScroll = false;
    }
}
