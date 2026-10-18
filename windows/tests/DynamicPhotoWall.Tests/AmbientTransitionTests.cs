using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Rendering;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

// Synthetic pixel arrays and presentation state only; no GUI renders/captures.
internal static class AmbientTransitionTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static BitmapSource Bitmap(byte[] pixel)
    {
        var image = BitmapSource.Create(1, 1, 96, 96, PixelFormats.Pbgra32, null, pixel, 4); image.Freeze(); return image;
    }
    public static Task ColorsFollowTimeWithoutFlashingOrLosingSaturation()
    {
        byte[] black = [0, 0, 0, 255], color = [20, 80, 240, 255];
        byte[] Response(int cadence)
        {
            var filter = new AmbientTransition(); filter.Push(black, 0); byte[] result = [];
            for (var i = 1; i <= cadence; i++) result = filter.Push(color, (double)i / cadence);
            return result;
        }
        Check(Response(8).SequenceEqual(Response(60)), "background response must depend on elapsed time rather than sample frequency");
        var transition = new AmbientTransition(); transition.Push(black, 0);
        var first = transition.Push(color, .125);
        Check(first[2] > 0 && first[2] < 40 && first[3] == 255, "a sudden photo change cannot jump half the color range in one sample");
        var held = transition.Push(color, .125);
        Check(held.SequenceEqual(first), "a paused clock holds background colors");
        var settled = transition.Push(color, 10);
        Check(settled.SequenceEqual(color), "steady backgrounds converge to their full vivid target color");
        var alternation = new AmbientTransition(); alternation.Push(black, 0); var last = black;
        for (var i = 1; i <= 50; i++)
        {
            var next = alternation.Push(i % 2 == 0 ? black : color, i * .125);
            Check(Math.Abs(next[2] - last[2]) < 40, "alternating Gallery colors remain bounded rather than flashing"); last = next;
        }
        return Task.CompletedTask;
    }
    public static Task LiveTextureRetargetsFromTheVisibleMix()
    {
        var brush = new ImageBrush(); var root = new Canvas(); var transitions = new TransitionController();
        using var presenter = new AmbientTexturePresenter(brush, root, transitions);
        presenter.SetFrame([0, 0, 255, 255], 1, 1, 0); var image = brush.ImageSource;
        presenter.SetFrame([255, 0, 0, 255], 1, 1, 1);
        presenter.SetFrame([0, 255, 0, 255], 1, 1, 1.0625);
        Check(ReferenceEquals(image, brush.ImageSource), "live updates must preserve the brush's drawing image");
        var drawing = (DrawingGroup)((DrawingImage)image).Drawing;
        var under = (BitmapSource)((ImageDrawing)drawing.Children[0]).ImageSource;
        var pixel = new byte[4]; under.CopyPixels(pixel, 4, 0);
        Check(pixel.SequenceEqual(new byte[] { 128, 0, 128, 255 }), "a mid-fade update starts from the displayed purple mix, not stale red or blue");
        Check(presenter.Texture?.IsFrozen == true, "computed textures remain immutable");
        presenter.Dispose(); Check(!drawing.Children[1].HasAnimatedProperties, "disposing a scene removes its ambient animation clock");
        return Task.CompletedTask;
    }
    public static Task SharedFrameBoundariesNeverSwapImageSources()
    {
        byte[][] colors = [[0, 0, 255, 255], [255, 0, 0, 255], [0, 255, 0, 255]];
        var textures = colors.Select(Bitmap).ToArray();
        var ambient = new AmbientFrameVisual([new(0, []), new(1, []), new(2, [])], textures, 400, 300);
        double[] Sample(double at)
        {
            ambient.Present(at); var result = new double[3];
            for (var i = 0; i < ambient.Images.Count; i++)
            {
                Check(ReferenceEquals(ambient.Images[i].Source, textures[i]), "shared playback must never replace an attached texture source");
                for (var c = 0; c < 3; c++) result[c] = colors[i][c] * ambient.Images[i].Opacity + result[c] * (1 - ambient.Images[i].Opacity);
            }
            Check(ambient.Images.Any(image => image.Opacity == 1), "an opaque base must cover the background throughout interpolation");
            return result;
        }
        foreach (var knot in new[] { 1d, 2d })
        {
            var before = Sample(knot - .00001); var after = Sample(knot + .00001);
            Check(before.Zip(after).All(pair => Math.Abs(pair.First - pair.Second) < .01), "sample boundaries must be perceptually continuous");
        }
        for (var i = 0; i <= 240; i++) Sample(i / 60d);
        Check(Sample(30).SequenceEqual(new double[] { 0, 255, 0 }), "a stalled or disconnected scene holds the final background");
        Check(Sample(0).SequenceEqual(new double[] { 0, 0, 255 }), "seeking or repeating resets opacity without swapping textures");
        return Task.CompletedTask;
    }
}
