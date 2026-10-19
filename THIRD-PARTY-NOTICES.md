# Third-party notices

Dynamic Photo Wall's original source code is licensed under the [MIT License](LICENSE).
Third-party software and test images retain their own licenses and notices.

## Windows distribution

The self-contained Windows application includes .NET, WPF / Windows Forms and
SkiaSharp. See [Windows notices](https://github.com/mhanayama/dynamic-photo-wall/blob/main/windows/THIRD-PARTY-NOTICES.md) for the components
and the license files included in the distribution. Keep those files when
redistributing the executable. The .NET SDK is a build tool; its top-level license
is not the license of this application or the bundled runtime.

## macOS distribution

The macOS application uses Apple's system frameworks, including SwiftUI, AppKit,
Vision, PhotoKit and CryptoKit. It does not bundle the Windows .NET or SkiaSharp
packages. Apple's frameworks and development tools remain subject to Apple's terms.

## Test images

`macos/DynamicPhotoWallTests/Fixtures/astronaut.png` (NASA / Eileen Collins) and
`hopper.webp` (US Navy / Grace Hopper) are public-domain test images. Their sources
and usage are recorded in the [fixture README](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/DynamicPhotoWallTests/Fixtures/README.md).
They are not included in application distributions. User photos, settings, keys
and caches are not part of the project's MIT license or release archives.
