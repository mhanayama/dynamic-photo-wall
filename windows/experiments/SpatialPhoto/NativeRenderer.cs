using System.Runtime.InteropServices;

namespace DpwSpatial;
internal sealed class NativeRenderer : IDisposable
{
    private nint handle;
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern nint SpatialCreate(nint hwnd, uint width, uint height, int warp);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern nint SpatialLastError();
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern nint SpatialAdapter(nint renderer);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern int SpatialSetImages(nint renderer, byte[] photo, uint w, uint h, byte[] depth, uint dw, uint dh);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern int SpatialRender(nint renderer, float position, float amplitude, int invert);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern int SpatialSetPortrait(nint renderer, float[] vertices, uint count, uint[] indices, uint indexCount, uint width, uint height, float fov, float pivot);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern int SpatialRenderPortraitTexture(nint renderer, float degrees, int usePhoto);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern int SpatialSetPortraitPhoto(nint renderer, byte[]? rgba, uint width, uint height);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern int SpatialResize(nint renderer, uint width, uint height);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern int SpatialReadback(nint renderer, [Out] byte[] data, uint length);
    [DllImport("DpwSpatialNative", CallingConvention = CallingConvention.Cdecl)] private static extern void SpatialDestroy(nint renderer);
    private static void Check(int status) { if (status != 0) throw new InvalidOperationException(Marshal.PtrToStringUni(SpatialLastError())); }
    public string Adapter => Marshal.PtrToStringUni(SpatialAdapter(handle)) ?? "unknown";
    public NativeRenderer(nint hwnd, int width, int height, bool warp = false) {
        handle = SpatialCreate(hwnd, (uint)width, (uint)height, warp ? 1 : 0);
        if (handle == 0) Check(-1);
    }
    public void SetPair(DepthPair pair) => SetImages(pair.Photo, pair.Depth, pair.DepthWidth, pair.DepthHeight);
    public void SetPortrait(PortraitScene scene) {
        SetImages(scene.Background, [128], 1, 1);
        if (scene.Vertices.Length % 8 != 0) throw new InvalidDataException("Invalid portrait vertex stride.");
        Check(SpatialSetPortrait(handle, scene.Vertices, (uint)(scene.Vertices.Length / 8), scene.Indices, (uint)scene.Indices.Length, (uint)scene.Width, (uint)scene.Height, scene.FovY, scene.Pivot));
        Check(SpatialSetPortraitPhoto(handle, scene.SourcePhoto?.Rgba, (uint)(scene.SourcePhoto?.Width ?? 0), (uint)(scene.SourcePhoto?.Height ?? 0)));
    }
    public void RenderPortrait(double degrees, bool usePhoto = true) { ObjectDisposedException.ThrowIf(handle == 0, this); Check(SpatialRenderPortraitTexture(handle, (float)degrees, usePhoto ? 1 : 0)); }
    public void SetImages(Pixels photo, byte[] depth, int dw, int dh) {
        ObjectDisposedException.ThrowIf(handle == 0, this);
        if (photo.Rgba.Length != checked(photo.Width * photo.Height * 4) || depth.Length != checked(dw * dh)) throw new ArgumentException("Image buffer size mismatch");
        Check(SpatialSetImages(handle, photo.Rgba, (uint)photo.Width, (uint)photo.Height, depth, (uint)dw, (uint)dh));
    }
    public void Render(double position, float amplitude, bool invert = false) { ObjectDisposedException.ThrowIf(handle == 0, this); Check(SpatialRender(handle, (float)position, amplitude, invert ? 1 : 0)); }
    public void Resize(int width, int height) { ObjectDisposedException.ThrowIf(handle == 0, this); Check(SpatialResize(handle, (uint)Math.Max(1, width), (uint)Math.Max(1, height))); }
    public byte[] Readback(int width, int height) { ObjectDisposedException.ThrowIf(handle == 0, this); var data = new byte[checked(width * height * 4)]; Check(SpatialReadback(handle, data, (uint)data.Length)); return data; }
    public void Dispose() { if (handle != 0) { SpatialDestroy(handle); handle = 0; } GC.SuppressFinalize(this); }
    ~NativeRenderer() => Dispose();
}
