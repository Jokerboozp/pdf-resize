using System.Threading;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PDFResize.Core.Engine;

namespace PDFResize.App;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // Fast headless exit for isolated child worker subprocesses (--worker-one req.json resp.json)
        if (WorkerCli.TryRun(args))
        {
            return Environment.ExitCode;
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });

        return 0;
    }
}
