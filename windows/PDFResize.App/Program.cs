using System.Threading;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PDFResize.Core.Engine;

namespace PDFResize.App;

public static class Program
{
    public static void LogCrash(string source, Exception? ex, string? rawMessage = null)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PDF Resize");
            Directory.CreateDirectory(dir);
            string logPath = Path.Combine(dir, "crash.log");
            string entry = $"[{DateTimeOffset.Now:O}] [{source}] {rawMessage ?? ex?.Message}\n{ex}\n\n";
            File.AppendAllText(logPath, entry);
        }
        catch { /* ignore logging failure */ }
    }

    [STAThread]
    public static int Main(string[] args)
    {
        // Fast headless exit for isolated child worker subprocesses (--worker-one req.json resp.json)
        if (WorkerCli.TryRun(args))
        {
            return Environment.ExitCode;
        }

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            LogCrash("AppDomain", e.ExceptionObject as Exception, e.ExceptionObject?.ToString());

        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start(_ =>
            {
                var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
                SynchronizationContext.SetSynchronizationContext(context);
                new App();
            });
            return 0;
        }
        catch (Exception ex)
        {
            LogCrash("Main", ex);
            return 1;
        }
    }
}
