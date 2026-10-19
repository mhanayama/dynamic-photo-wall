# Third-party components — Windows

Dynamic Photo Wall itself is licensed under MIT; see `LICENSE` in the distribution
or the [repository license](https://github.com/mhanayama/dynamic-photo-wall/blob/main/LICENSE).
The Windows executable also bundles the following components. Their original
license and notice texts are copied from the restored packages during the build.

| Component | License | Distribution files |
|---|---|---|
| .NET runtime | MIT and third-party notices | `DotNet-LICENSE.txt`, `DotNet-THIRD-PARTY-NOTICES.txt` |
| Windows Desktop runtime (WPF / Windows Forms) | MIT | `WindowsDesktop-LICENSE.txt` |
| SkiaSharp 3.119.4 | MIT | `SkiaSharp-Managed-LICENSE.txt` |
| SkiaSharp.NativeAssets.Win32 3.119.4, including Skia and codecs | MIT and component-specific licenses | `SkiaSharp-LICENSE.txt`, `SkiaSharp-THIRD-PARTY-NOTICES.txt` |

SkiaSharp handles local WebP decoding and dynamic background blurring.
The exact runtime and package versions are recorded in `BUILD-INFO.txt`.
Keep `LICENSE`, this document and all the listed files when redistributing.

Upstream projects: [.NET](https://github.com/dotnet/runtime),
[WPF](https://github.com/dotnet/wpf), [Windows Forms](https://github.com/dotnet/winforms),
[SkiaSharp](https://github.com/mono/SkiaSharp), [Skia](https://skia.org/docs/user/license/).
