# Third-party components

The application uses .NET / WPF (Microsoft, MIT) and SkiaSharp 3.119.4 (Microsoft / Mono contributors, MIT).
SkiaSharp is used for local WebP decoding and blurring the dynamic ambient background. Its Windows native assets include Skia and codec dependencies with their own permissive licenses.

- .NET license: https://github.com/dotnet/runtime/blob/main/LICENSE.TXT
- WPF license: https://github.com/dotnet/wpf/blob/main/LICENSE.TXT
- SkiaSharp license and notices: https://github.com/mono/SkiaSharp
- Skia third-party licenses: https://skia.org/docs/user/license/

The release folder includes the upstream .NET LICENSE.txt / ThirdPartyNotices.txt and SkiaSharp native notices. Preserve those files when redistributing.
