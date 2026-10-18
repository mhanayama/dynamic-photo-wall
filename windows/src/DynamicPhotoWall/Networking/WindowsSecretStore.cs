using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

// Windows API is restricted to this adapter; the network library receives ISecretStore.
public sealed class WindowsSecretStore(string directory) : Net.ISecretStore
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Count; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob data, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob data, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        var input = new Blob { Count = bytes.Length, Data = pointer }; Blob output = default;
        try
        {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
            var ok = protect ? CryptProtectData(ref input, "Dynamic Photo Wall", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new CryptographicException(Marshal.GetLastWin32Error());
            var result = new byte[output.Count]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally
        {
            Marshal.Copy(new byte[bytes.Length], 0, pointer, bytes.Length); Marshal.FreeHGlobal(pointer);
            if (output.Data != IntPtr.Zero) { Marshal.Copy(new byte[output.Count], 0, output.Data, output.Count); LocalFree(output.Data); }
        }
    }
    private string PathFor(string name)
    {
        if (name.Length > 64 || !name.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')) throw new ArgumentException("Invalid secret name.");
        return Path.Combine(directory, name + ".protected");
    }
    public byte[]? Read(string name) => File.Exists(PathFor(name)) ? Transform(File.ReadAllBytes(PathFor(name)), false) : null;
    public void Write(string name, byte[] value)
    {
        Directory.CreateDirectory(directory); var path = PathFor(name); var temporary = path + ".tmp";
        try { File.WriteAllBytes(temporary, Transform(value, true)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
