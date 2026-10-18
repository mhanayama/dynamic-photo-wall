using DynamicPhotoWall.Core;

namespace DynamicPhotoWall.Tests;

internal static class GalleryBehaviorTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static PhotoInfo Photo(string id, int width = 600, int height = 1800) => new(id, width, height, 1, null, 1, 0);
    public static Task Run()
    {
        var settings = new WallSettings { RecentCount = 0 };
        var offCenterFace = Photo("face", 2000, 6000) with { Faces = [new(.65, .15, .12, .4)] };
        foreach (var viewport in new[] { new Viewport(1920, 1080), new Viewport(1280, 1024) })
        {
            var pan = FaceMotionSafety.Plan(CompositionMode.VerticalPan, offCenterFace, viewport, settings);
            Check(Math.Abs(pan.FromX + pan.Width / 2 - viewport.Width / 2) < .001 && pan.FromX == pan.ToX,
                "each mirrored output centers the photograph even when its face is off center");
        }
        var galleryFace = Photo("gallery-face", 300, 1000) with { Faces = [new(.2, .2, .2, .2)] };
        var frame = FixedGalleryLayout.Arrange([galleryFace], new(3000, 1000), 8,
            [new(0, 0, 1000, 1000), new(1000, 0, 1000, 1000), new(2000, 0, 1000, 1000)]).Single().Frame;
        Check(Math.Abs(frame.X + frame.Width / 2 - 1500) < .001, "a safe center on another physical output is preferred over pinning the row left");
        foreach (var vertical in new[] { false, true })
        {
            var viewport = vertical ? new Viewport(1080, 4000) : new Viewport(4000, 1080);
            var photos = Enumerable.Range(0, 3).Select(i => vertical ? Photo(i.ToString(), 1800, 600) : Photo(i.ToString())).ToArray();
            var incoming = vertical ? Photo("new", 1800, 600) : Photo("new");
            var change = FixedGalleryLayout.Update(photos, incoming, viewport, 8, [], 0, 5)!;
            Check(change.IsAddition && change.Items.Count == 4 && photos.All(change.Photos.Contains), "free padding adds a card without evicting existing cards");
            Check(change.Items.All(i => Math.Abs((vertical ? i.Frame.Width : i.Frame.Height) - 1064) < .001), "adding cards preserves the fixed short axis");
            Check(!FixedGalleryLayout.Update(photos, incoming, viewport, 8, [], 0, 3)!.IsAddition, "the configured maximum still bounds additions");
            Check(FixedGalleryLayout.Update(photos, photos[0], viewport, 8, [], 0, 5) == null, "an active photo cannot be added or replace itself");
        }
        var random = new Random(2); var rotation = new GalleryRotation();
        var active = Enumerable.Range(0, 4).Select(i => Photo(i.ToString())).ToArray();
        var originals = active.Select(p => p.Path).ToHashSet();
        for (var i = 0; i < 4; i++)
        {
            var index = rotation.Choose(active, random);
            Check(originals.Remove(active[index].Path), "incoming photos cannot replace one another before the old photos have all had their turn");
            active[index] = Photo($"new-{i}"); rotation.Inserted(active[index]);
        }
        var selector = new PhotoSelector(new Random(1)); var library = Enumerable.Range(0, 12).Select(i => Photo(i.ToString())).ToArray();
        for (var round = 0; round < 3; round++)
            Check(Enumerable.Range(0, library.Length).Select(_ => selector.Pick(library, settings)!.Path).Distinct().Count() == library.Length,
                "selection flags visit every eligible photograph before repeating even with history disabled");
        return Task.CompletedTask;
    }
}
