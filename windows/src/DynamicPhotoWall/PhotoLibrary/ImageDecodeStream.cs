namespace DynamicPhotoWall.PhotoLibrary;

// BitmapImage keeps StreamSource even with OnLoad. Drop the backing stream on
// disposal so a displayed bitmap cannot pin its no-longer-needed input array.
internal sealed class ImageDecodeStream(byte[] data) : Stream
{
    private MemoryStream? source = new(data, writable: false);
    private MemoryStream Source => source ?? throw new ObjectDisposedException(nameof(ImageDecodeStream));
    public override bool CanRead => source?.CanRead == true;
    public override bool CanSeek => source?.CanSeek == true;
    public override bool CanWrite => false;
    public override long Length => Source.Length;
    public override long Position { get => Source.Position; set => Source.Position = value; }
    public override int Read(byte[] buffer, int offset, int count) => Source.Read(buffer, offset, count);
    public override int Read(Span<byte> buffer) => Source.Read(buffer);
    public override int ReadByte() => Source.ReadByte();
    public override long Seek(long offset, SeekOrigin origin) => Source.Seek(offset, origin);
    public override void Flush() => Source.Flush();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing)
    {
        if (disposing) { source?.Dispose(); source = null; }
        base.Dispose(disposing);
    }
}
