$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PhotoWallShellInspection {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h,int i);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    static string Class(IntPtr h) { var b=new StringBuilder(256); GetClassName(h,b,b.Capacity); return b.ToString(); }
    static void Dump(IntPtr h,int depth,StringBuilder output) {
        GetWindowRect(h,out var r); GetWindowThreadProcessId(h,out var pid);
        output.AppendLine(new string(' ',depth*2)+$"0x{h.ToInt64():X} {Class(h)} pid={pid} visible={IsWindowVisible(h)} style=0x{GetWindowLongPtr(h,-16).ToInt64():X} ex=0x{GetWindowLongPtr(h,-20).ToInt64():X} rect=({r.Left},{r.Top},{r.Right},{r.Bottom})");
        if(depth>=3) return;
        for(var child=FindWindowEx(h,IntPtr.Zero,null,null); child!=IntPtr.Zero; child=FindWindowEx(h,child,null,null)) Dump(child,depth+1,output);
    }
    public static string Inspect() {
        var context=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { var b=new StringBuilder(); EnumWindows((h,p)=> { var c=Class(h); if(c=="Progman" || c=="WorkerW" || c=="Shell_TrayWnd" || c=="Shell_SecondaryTrayWnd") Dump(h,0,b); return true; },IntPtr.Zero); return b.ToString(); }
        finally { SetThreadDpiAwarenessContext(context); }
    }
}
'@
Get-Process | Where-Object { $_.ProcessName -like '*PhotoWall*' } | Select-Object Id,ProcessName,MainWindowTitle,Path | ConvertTo-Json
[PhotoWallShellInspection]::Inspect()
