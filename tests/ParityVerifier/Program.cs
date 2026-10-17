using System.Text.Json;
using System.Text.Json.Serialization;
using DynamicPhotoWall.Core;

var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
var generate = args.Contains("--generate");
var path = args.LastOrDefault(a => a != "--generate" && a != "--generate-delta") ?? "macos/DynamicPhotoWallTests/Fixtures/WindowsParity.json";
if (args.Contains("--generate-delta") || Path.GetFileName(path) == "WindowsDelta.json")
{
    DeltaVerifier.Run(path, args.Contains("--generate-delta"), options);
    return;
}
if (generate)
{
    var cases = new List<MotionCase>();
    foreach (var v in new[] { new Viewport(1920,1080), new Viewport(3840,2160), new Viewport(3440,1440) })
    foreach (var dimensions in new[] { (800,2400), (6000,1200), (2400,1600), (1641,1640) })
    foreach (var mode in new[] { CompositionMode.VerticalPan, CompositionMode.HorizontalPan, CompositionMode.Zoom })
    {
        IReadOnlyList<FaceRegion>? faces = cases.Count % 2 == 0 ? [new(.1,.03,.25,.3), new(.6,.5,.1,.15)] : null;
        var photo = new PhotoInfo($"/fixture/{cases.Count}.jpg", dimensions.Item1, dimensions.Item2, 1, null, 1, 0, faces);
        // This shared suite preserves the macOS v1.0.1 baseline. New face-directed
        // pan and display-boundary cases live separately in DeltaVerifier.cs.
        var s = new WallSettings { FaceAwarePanDirection = false, StopAtFace = cases.Count % 3 != 0, FaceAwareFraming = cases.Count % 4 != 0 };
        var reverse = cases.Count % 2 != 0;
        var plan = MotionEngine.Plan(mode, photo, v, s, reverse, .37, .63);
        cases.Add(new($"{mode}-{cases.Count}", mode, photo.Width, photo.Height, faces, v, s, reverse, .37, .63, plan,
            Enum.GetValues<CompositionMode>().ToDictionary(m => m, m => new MetadataCompositionPolicy().Suitable(photo,v,m,s))));
    }
    var layouts = new List<LayoutCase>();
    foreach (var gap in new[] { 0d, 8d, 200d })
    foreach (var count in new[] { 1, 3, 5 })
    {
        var photos = Enumerable.Range(0,count).Select(i => new PhotoInfo($"/fixture/{i}.jpg", i % 2 == 0 ? 800 : 2400,1600,1,null,1,0)).ToArray();
        var v = new Viewport(1920,1080);
        layouts.Add(new(gap, v, photos.Select(p => new Dimensions(p.Width,p.Height)).ToArray(), CompositionEngine.GalleryLayout(photos,v,gap)));
    }
    var selection = new List<SelectorCase>();
    foreach (var recentCount in new[] { 0, 30 })
    {
        var photos = new[] { "/c.jpg", "/a.jpg", "/b.jpg" };
        var excluded = Enumerable.Range(0,10).Select(_ => new[] { "/c.jpg" }).ToArray();
        var selector = new PhotoSelector(new Random(42));
        var settings = new WallSettings { RandomOrder=false, RecentCount=recentCount };
        var pool = photos.Select(p=>new PhotoInfo(p,100,200,1,null,1,0)).ToArray();
        var expected = excluded.Select(e=>selector.Pick(pool,settings,e.ToHashSet())?.Path).ToArray();
        selection.Add(new(photos,recentCount,excluded,expected));
    }
    File.WriteAllText(path, JsonSerializer.Serialize(new Fixtures(cases, layouts, selection),options));
}
var fixture = JsonSerializer.Deserialize<Fixtures>(File.ReadAllText(path), options)!;
var checks = 0;
foreach (var c in fixture.Motion)
{
    var photo = new PhotoInfo("/fixture/test.jpg",c.Width,c.Height,1,null,1,0,c.Faces);
    var plan = MotionEngine.Plan(c.Mode,photo,c.Viewport,c.Settings,c.Reverse,c.CenterX,c.CenterY);
    var actual = new[] {plan.Width,plan.Height,plan.FromX,plan.FromY,plan.ToX,plan.ToY,plan.FromScale,plan.ToScale,plan.CenterX,plan.CenterY,plan.Seconds};
    var p = c.Expected;
    var expected = new[] {p.Width,p.Height,p.FromX,p.FromY,p.ToX,p.ToY,p.FromScale,p.ToScale,p.CenterX,p.CenterY,p.Seconds};
    for (var i=0;i<actual.Length;i++) { if (Math.Abs(actual[i]-expected[i])>1e-7) throw new Exception($"{c.Name}: field {i}"); checks++; }
    foreach (var pair in c.Eligible) { if (new MetadataCompositionPolicy().Suitable(photo,c.Viewport,pair.Key,c.Settings)!=pair.Value) throw new Exception($"{c.Name}: eligibility {pair.Key}"); checks++; }
}
foreach (var l in fixture.Layout)
{
    var photos = l.Photos.Select((p,i)=>new PhotoInfo($"/{i}",p.Width,p.Height,1,null,1,0)).ToArray();
    var actual = CompositionEngine.GalleryLayout(photos,l.Viewport,l.Gap);
    for(var i=0;i<actual.Count;i++)
    {
        var a=actual[i]; var b=l.Expected[i];
        foreach(var d in new[]{a.X-b.X,a.Y-b.Y,a.Width-b.Width,a.Height-b.Height}) { if(Math.Abs(d)>1e-7) throw new Exception("Gallery layout mismatch"); checks++; }
    }
}
foreach (var c in fixture.Selection)
{
    var selector = new PhotoSelector(new Random(42));
    var settings = new WallSettings { RandomOrder=false, RecentCount=c.RecentCount };
    var photos = c.Photos.Select(p=>new PhotoInfo(p,100,200,1,null,1,0)).ToArray();
    for(var i=0;i<c.Excluded.Count;i++)
    {
        if(selector.Pick(photos,settings,c.Excluded[i].ToHashSet())?.Path!=c.Expected[i]) throw new Exception("Selection history/exclusion mismatch");
        checks++;
    }
}
Console.WriteLine($"PASS: {fixture.Motion.Count} motion/eligibility cases, {fixture.Layout.Count} gallery layouts, {fixture.Selection.Count} selector cases, {checks} assertions against shared fixtures.");
record MotionCase(string Name,CompositionMode Mode,int Width,int Height,IReadOnlyList<FaceRegion>? Faces,Viewport Viewport,WallSettings Settings,bool Reverse,double CenterX,double CenterY,MotionPlan Expected,Dictionary<CompositionMode,bool> Eligible);
record Dimensions(int Width,int Height);
record LayoutCase(double Gap,Viewport Viewport,IReadOnlyList<Dimensions> Photos,IReadOnlyList<FrameRect> Expected);
record SelectorCase(IReadOnlyList<string> Photos,int RecentCount,IReadOnlyList<string[]> Excluded,IReadOnlyList<string?> Expected);
record Fixtures(IReadOnlyList<MotionCase> Motion,IReadOnlyList<LayoutCase> Layout,IReadOnlyList<SelectorCase> Selection);
