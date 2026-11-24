using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace PDFResize.App.Interop;

public static class NativeFolderPicker
{
    private const uint FOS_PICKFOLDERS = 0x00000020;
    private const uint FOS_FORCEFILESYSTEM = 0x00000040;
    private const uint FOS_ALLOWMULTISELECT = 0x00000200;
    private const uint FOS_PATHMUSTEXIST = 0x00000800;
    private const uint SIGDN_FILESYSPATH = 0x80058000;
    private const int ERROR_CANCELLED_HR = unchecked((int)0x800704C7);

    private static readonly Guid CLSID_FileOpenDialog = new("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7");

    /// <summary>
    /// Opens a native Windows 11 Explorer dialog supporting Ctrl / Shift multi-folder selection.
    /// Falls back to WinRT FolderPicker if COM activation is unavailable.
    /// </summary>
    public static async Task<IReadOnlyList<string>> PickMultipleFoldersAsync(Window ownerWindow, string title = "选择要批量压缩的文件夹（支持按住 Ctrl / Shift 多选）")
    {
        IntPtr hwnd = WindowNative.GetWindowHandle(ownerWindow);

        try
        {
            Type? dlgType = Type.GetTypeFromCLSID(CLSID_FileOpenDialog, throwOnError: false);
            if (dlgType is not null && Activator.CreateInstance(dlgType) is IFileOpenDialog dialog)
            {
                try
                {
                    dialog.GetOptions(out uint options);
                    dialog.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_ALLOWMULTISELECT | FOS_PATHMUSTEXIST);
                    dialog.SetTitle(title);
                    dialog.SetOkButtonLabel("添加所选文件夹");

                    int hr = dialog.Show(hwnd);
                    if (hr == ERROR_CANCELLED_HR || hr != 0)
                        return [];

                    dialog.GetResults(out IShellItemArray results);
                    results.GetCount(out uint count);

                    var list = new List<string>((int)count);
                    for (uint i = 0; i < count; i++)
                    {
                        results.GetItemAt(i, out IShellItem item);
                        item.GetDisplayName(SIGDN_FILESYSPATH, out string path);
                        if (!string.IsNullOrWhiteSpace(path))
                            list.Add(path);
                    }
                    return list;
                }
                finally
                {
                    Marshal.FinalReleaseComObject(dialog);
                }
            }
        }
        catch
        {
            // Fall through to WinRT single-folder picker
        }

        string? single = await PickSingleFolderAsync(ownerWindow);
        return single is not null ? [single] : [];
    }

    public static async Task<string?> PickSingleFolderAsync(Window ownerWindow)
    {
        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary
        };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(ownerWindow));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    public static async Task<IReadOnlyList<string>> PickPdfFilesAsync(Window ownerWindow, bool allowMultiple = true)
    {
        var picker = new FileOpenPicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            ViewMode = PickerViewMode.List
        };
        picker.FileTypeFilter.Add(".pdf");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(ownerWindow));

        if (allowMultiple)
        {
            var files = await picker.PickMultipleFilesAsync();
            return files?.Select(f => f.Path).Where(p => !string.IsNullOrWhiteSpace(p)).ToList() ?? [];
        }
        else
        {
            var file = await picker.PickSingleFileAsync();
            return file is not null && !string.IsNullOrWhiteSpace(file.Path) ? [file.Path] : [];
        }
    }

    public static void RevealInExplorer(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try
        {
            string full = Path.GetFullPath(path);
            if (File.Exists(full))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"/select,\"{full}\"",
                    UseShellExecute = true
                });
            }
            else if (Directory.Exists(full))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"\"{full}\"",
                    UseShellExecute = true
                });
            }
        }
        catch { /* ignore */ }
    }

    public static void OpenWithDefaultApp(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = Path.GetFullPath(path),
                UseShellExecute = true
            });
        }
        catch { /* ignore */ }
    }

    [ComImport]
    [Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogRCW { }

    [ComImport]
    [Guid("d57c7288-d4ad-4768-be02-9d969532d960")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(in Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IShellItemArray ppenum);
        void GetSelectedItems(out IShellItemArray ppsai);
    }

    [ComImport]
    [Guid("b63ea76d-1f85-456f-a19c-48159efa858b")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemArray
    {
        void BindToHandler(IntPtr pbc, in Guid bhid, in Guid riid, out IntPtr ppvOut);
        void GetPropertyStore(int flags, in Guid riid, out IntPtr ppv);
        void GetPropertyDescriptionList(IntPtr keyType, in Guid riid, out IntPtr ppv);
        void GetAttributes(int attribFlags, uint sfgaoMask, out uint psfgaoAttribs);
        void GetCount(out uint pdwNumItems);
        void GetItemAt(uint dwIndex, out IShellItem ppsi);
        void EnumItems(out IntPtr ppenumShellItems);
    }

    [ComImport]
    [Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, in Guid bhid, in Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }
}
