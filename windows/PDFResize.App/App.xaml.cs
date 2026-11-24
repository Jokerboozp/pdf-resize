using Microsoft.UI.Xaml;
using PDFResize.App.ViewModels;

namespace PDFResize.App;

public partial class App : Application
{
    public static AppState State { get; } = new();
    public static MainWindow? MainWindowInstance { get; private set; }

    public App()
    {
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        MainWindowInstance = new MainWindow();
        MainWindowInstance.Activate();
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        Program.LogCrash("XamlUnhandled", e.Exception, e.Message);
        e.Handled = true;
        State.ShowBanner("运行提示", e.Message, Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error);
    }
}
