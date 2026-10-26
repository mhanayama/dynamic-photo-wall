using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using ComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace DpwSpatial;

internal static class PhotoDrop
{
    public static bool TrySelect(string[]? files, out string path, out string reason)
    {
        path = "";
        reason = "JPEG・PNG・WebPの画像を1枚ドロップしてください。";
        if (files is not { Length: 1 }) return false;
        try {
            var candidate = Path.GetFullPath(files[0]);
            if (!new[] { ".jpg", ".jpeg", ".png", ".webp" }.Contains(Path.GetExtension(candidate), StringComparer.OrdinalIgnoreCase) || !File.Exists(candidate)) return false;
            path = candidate; reason = ""; return true;
        } catch (Exception e) when (e is ArgumentException or NotSupportedException or IOException) { return false; }
    }

    // CF_HDROP belongs to the IDataObject's STGMEDIUM: release it, never DragFinish it.
    public static string[] ReadFiles(ComDataObject data)
    {
        var format = new FORMATETC { cfFormat = 15, dwAspect = DVASPECT.DVASPECT_CONTENT, lindex = -1, tymed = TYMED.TYMED_HGLOBAL };
        if (data.QueryGetData(ref format) != 0) return [];
        data.GetData(ref format, out var medium);
        try {
            if (medium.tymed != TYMED.TYMED_HGLOBAL || medium.unionmember == 0) return [];
            var count = DragQueryFile(medium.unionmember, uint.MaxValue, null, 0);
            if (count != 1) return []; // This trial intentionally accepts one photo at a time.
            var length = DragQueryFile(medium.unionmember, 0, null, 0);
            if (length is 0 or > 32767) return [];
            var path = new StringBuilder((int)length + 1);
            DragQueryFile(medium.unionmember, 0, path, (uint)path.Capacity);
            return [path.ToString()];
        } finally { ReleaseStgMedium(ref medium); }
    }

    [DllImport("shell32", EntryPoint = "DragQueryFileW", CharSet = CharSet.Unicode)] private static extern uint DragQueryFile(nint drop, uint index, StringBuilder? path, uint length);
    [DllImport("ole32")] private static extern void ReleaseStgMedium(ref STGMEDIUM medium);
}

[StructLayout(LayoutKind.Sequential)]
public struct DropPoint { public int X, Y; }

[ComVisible(true), Guid("00000122-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPhotoDropTarget
{
    [PreserveSig] int DragEnter([MarshalAs(UnmanagedType.Interface)] ComDataObject data, uint keys, DropPoint point, ref uint effect);
    [PreserveSig] int DragOver(uint keys, DropPoint point, ref uint effect);
    [PreserveSig] int DragLeave();
    [PreserveSig] int Drop([MarshalAs(UnmanagedType.Interface)] ComDataObject data, uint keys, DropPoint point, ref uint effect);
}

// A WPF Drop handler alone cannot cover the native D3D12 child HWND.
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class NativePhotoDrop : IPhotoDropTarget, IDisposable
{
    private nint hwnd;
    private bool acceptable;
    private readonly Action<string> dropped;
    public NativePhotoDrop(nint hwnd, Action<string> dropped)
    {
        this.dropped = dropped;
        Marshal.ThrowExceptionForHR(OleInitialize(0));
        try { Marshal.ThrowExceptionForHR(RegisterDragDrop(hwnd, this)); this.hwnd = hwnd; }
        catch { OleUninitialize(); throw; }
    }
    public int DragEnter(ComDataObject data, uint keys, DropPoint point, ref uint effect)
    {
        try { acceptable = PhotoDrop.TrySelect(PhotoDrop.ReadFiles(data), out _, out _); }
        catch { acceptable = false; }
        effect = acceptable ? effect & 1u : 0; return 0;
    }
    public int DragOver(uint keys, DropPoint point, ref uint effect) { effect = acceptable ? effect & 1u : 0; return 0; }
    public int DragLeave() { acceptable = false; return 0; }
    public int Drop(ComDataObject data, uint keys, DropPoint point, ref uint effect)
    {
        try {
            if ((effect & 1u) != 0 && PhotoDrop.TrySelect(PhotoDrop.ReadFiles(data), out var path, out _)) { effect = 1; dropped(path); }
            else effect = 0;
        } catch { effect = 0; }
        acceptable = false; return 0;
    }
    public void Dispose()
    {
        if (hwnd == 0) return;
        RevokeDragDrop(hwnd); hwnd = 0; OleUninitialize();
    }
    [DllImport("ole32")] private static extern int OleInitialize(nint reserved);
    [DllImport("ole32")] private static extern void OleUninitialize();
    [DllImport("ole32")] private static extern int RegisterDragDrop(nint hwnd, [MarshalAs(UnmanagedType.Interface)] IPhotoDropTarget target);
    [DllImport("ole32")] private static extern int RevokeDragDrop(nint hwnd);
}
