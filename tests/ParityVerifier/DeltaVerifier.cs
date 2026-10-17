using System.Text.Json;
using DynamicPhotoWall.Core;

// Separate from the immutable 36-case v1.0.1 baseline.
static class DeltaVerifier
{
    public static void Run(string path, bool generate, JsonSerializerOptions options)
    {
        if (generate)
        {
            var cases = new List<DeltaMotion>();
            var v = new Viewport(1000,600);
            foreach (var vertical in new[]{true,false})
            foreach (var face in new[]{new FaceRegion(.4,.05,.2,.1),new(.4,.85,.2,.1),new(.05,.3,.1,.2),new(.85,.3,.1,.2),new(.45,.45,.1,.1)})
            foreach (var stop in new[]{true,false})
            {
                var s = new WallSettings { PanWidthFraction=1, FaceAwarePanDirection=true, StopAtFace=stop };
                var photo = new PhotoInfo("/fixture/face.jpg",vertical?1000:3000,vertical?2000:600,1,null,1,0,[face]);
                var mode = vertical ? CompositionMode.VerticalPan : CompositionMode.HorizontalPan;
                cases.Add(new(mode,photo.Width,photo.Height,photo.Faces!,v,s,true,[],MotionEngine.Plan(mode,photo,v,s,true)));
            }
            var layouts = new List<DeltaLayout>();
            var regions = new[]{
                new[]{new FrameRect(0,0,1000,600),new FrameRect(1000,0,1000,600)},
                new[]{new FrameRect(0,0,2000,300),new FrameRect(0,300,2000,300)},
                new[]{new FrameRect(0,0,900,600),new FrameRect(1100,50,900,550)},
                new[]{new FrameRect(1000,0,1000,600)}
            };
            var photos = new[]{
                new PhotoInfo("/a.jpg",800,2000,1,null,1,0,[new(.4,.1,.2,.15),new(.6,.3,.15,.2)]),
                new PhotoInfo("/b.jpg",1000,2000,1,null,1,0,[new(.1,.6,.6,.35)]),
                new PhotoInfo("/c.jpg",1000,600,1,null,1,0,[])
            };
            foreach(var displays in regions)
            {
                var wall = new Viewport(2000,600);
                layouts.Add(new(wall,8,photos.Select(p=>new DeltaPhoto(p.Width,p.Height,p.Faces!)).ToArray(),displays,FaceSafeLayout.Gallery(photos,wall,8,displays)));
                foreach(var photo in photos.Take(2))
                foreach(var stop in new[]{false,true})
                foreach(var direction in new[]{false,true})
                {
                    var s = new WallSettings{PanWidthFraction=1,StopAtFace=stop,FaceAwarePanDirection=direction};
                    cases.Add(new(CompositionMode.VerticalPan,photo.Width,photo.Height,photo.Faces!,wall,s,false,displays,MotionEngine.Plan(CompositionMode.VerticalPan,photo,wall,s,displayRegions:displays)));
                }
            }
            var fill = new List<DeltaFill>();
            var fv = new Viewport(800,300); FrameRect[] fd = [new(0,0,400,300),new(400,0,400,300)];
            var a = new DeltaFillPhoto(400,800,[new(.25,.1,.5,.3)]);
            var bad = new DeltaFillPhoto(1600,800,[new(.25,.1,.5,.3)]);
            var good = new DeltaFillPhoto(1600,800,[new(.6,.1,.2,.3)]);
            foreach(var (basePhotos,candidates) in new[]{
                (new[]{a,bad},new[]{good}), (new[]{a,bad},new[]{good with { Faces=null }}),
                (new[]{a,bad},new[]{good with { Faces=[] }}), (new[]{a,good},new[]{bad}) })
            {
                var originals=basePhotos.Select((p,i)=>new PhotoInfo($"/photo/{i}",p.Width,p.Height,1,null,1,0,p.Faces)).ToArray();
                var trial=candidates.Select((p,i)=>new PhotoInfo($"/candidate/{i}",p.Width,p.Height,1,null,1,0,p.Faces)).ToArray();
                var better=GalleryComposition.Improve(originals,trial,fv,8,fd,1);
                fill.Add(new(basePhotos,candidates,fv,8,fd,1,GalleryComposition.Loss(originals,fv,8,fd),better?.Index,better==null?null:Array.IndexOf(trial,better.Photo)));
            }
            File.WriteAllText(path,JsonSerializer.Serialize(new DeltaFixtures(cases,layouts,fill),options));
        }
        var fixture=JsonSerializer.Deserialize<DeltaFixtures>(File.ReadAllText(path),options)!;
        var checks=0;
        foreach(var c in fixture.Motion)
        {
            var photo=new PhotoInfo("/fixture.jpg",c.Width,c.Height,1,null,1,0,c.Faces);
            var a=MotionEngine.Plan(c.Mode,photo,c.Viewport,c.Settings,c.Reverse,displayRegions:c.Displays);
            var b=c.Expected;
            foreach(var delta in new[]{a.Width-b.Width,a.Height-b.Height,a.FromX-b.FromX,a.ToX-b.ToX,a.FromY-b.FromY,a.ToY-b.ToY,a.Seconds-b.Seconds,(a.FrameTop ?? (c.Viewport.Height-Math.Min(c.Viewport.Height,a.Height))/2)-(b.FrameTop ?? (c.Viewport.Height-Math.Min(c.Viewport.Height,b.Height))/2)})
            { if(Math.Abs(delta)>1e-7) throw new Exception("Delta motion mismatch"); checks++; }
        }
        foreach(var c in fixture.FaceLayout)
        {
            var photos=c.Photos.Select((p,i)=>new PhotoInfo($"/{i}",p.Width,p.Height,1,null,1,0,p.Faces)).ToArray();
            var actual=FaceSafeLayout.Gallery(photos,c.Viewport,c.Gap,c.Displays);
            for(var i=0;i<actual.Count;i++) foreach(var delta in new[]{actual[i].X-c.Expected[i].X,actual[i].Y-c.Expected[i].Y,actual[i].Width-c.Expected[i].Width,actual[i].Height-c.Expected[i].Height})
            { if(Math.Abs(delta)>1e-7) throw new Exception("Delta gallery mismatch"); checks++; }
        }
        foreach(var c in fixture.GalleryFill ?? [])
        {
            var photos=c.Photos.Select((p,i)=>new PhotoInfo($"/photo/{i}",p.Width,p.Height,1,null,1,0,p.Faces)).ToArray();
            var candidates=c.Candidates.Select((p,i)=>new PhotoInfo($"/candidate/{i}",p.Width,p.Height,1,null,1,0,p.Faces)).ToArray();
            if(Math.Abs(GalleryComposition.Loss(photos,c.Viewport,c.Gap,c.Displays)-c.ExpectedLoss)>1e-7) throw new Exception("Gallery loss mismatch"); checks++;
            var better=GalleryComposition.Improve(photos,candidates,c.Viewport,c.Gap,c.Displays,c.OnlyIndex);
            if(better?.Index!=c.ExpectedIndex || (better==null?null:(int?)Array.IndexOf(candidates,better.Photo))!=c.ExpectedCandidate) throw new Exception("Gallery replacement mismatch"); checks++;
        }
        Console.WriteLine($"PASS: {fixture.Motion.Count} delta motion cases, {fixture.FaceLayout.Count} face-safe layouts, {fixture.GalleryFill?.Count ?? 0} Gallery fill cases, {checks} assertions.");
    }
}
record DeltaPhoto(int Width,int Height,IReadOnlyList<FaceRegion> Faces);
record DeltaMotion(CompositionMode Mode,int Width,int Height,IReadOnlyList<FaceRegion> Faces,Viewport Viewport,WallSettings Settings,bool Reverse,IReadOnlyList<FrameRect> Displays,MotionPlan Expected);
record DeltaLayout(Viewport Viewport,double Gap,IReadOnlyList<DeltaPhoto> Photos,IReadOnlyList<FrameRect> Displays,IReadOnlyList<FrameRect> Expected);
record DeltaFillPhoto(int Width,int Height,IReadOnlyList<FaceRegion>? Faces);
record DeltaFill(IReadOnlyList<DeltaFillPhoto> Photos,IReadOnlyList<DeltaFillPhoto> Candidates,Viewport Viewport,double Gap,IReadOnlyList<FrameRect> Displays,int? OnlyIndex,double ExpectedLoss,int? ExpectedIndex,int? ExpectedCandidate);
record DeltaFixtures(IReadOnlyList<DeltaMotion> Motion,IReadOnlyList<DeltaLayout> FaceLayout,IReadOnlyList<DeltaFill>? GalleryFill = null);
