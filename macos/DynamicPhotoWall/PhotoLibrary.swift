import Foundation
import ImageIO

enum PhotoLibrary {
    nonisolated static var supportedExtensions: Set<String> {
        ["heic", "heif", "jpeg", "jpg", "png", "webp"]
    }

    nonisolated static func scan(folderURL: URL, recursive: Bool = true) async -> [PhotoAsset] {
        let task = Task.detached(priority: .userInitiated) {
            scanSynchronously(folderURL: folderURL, recursive: recursive)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func scanSynchronously(
        folderURL: URL,
        recursive: Bool
    ) -> [PhotoAsset] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants
        ]
        if !recursive {
            options.insert(.skipsSubdirectoryDescendants)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var photos: [PhotoAsset] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { return [] }
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isHidden != true,
                  let asset = makeAsset(url: url) else {
                continue
            }
            photos.append(asset)
        }

        return photos.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private nonisolated static func makeAsset(url: URL) -> PhotoAsset? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = (5...8).contains(orientation)
        let pixelWidth = swapsDimensions ? height.intValue : width.intValue
        let pixelHeight = swapsDimensions ? width.intValue : height.intValue

        guard pixelWidth > 0, pixelHeight > 0, pixelWidth <= 500_000_000 / pixelHeight else {
            return nil
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return PhotoAsset(
            url: url.standardizedFileURL,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fileSize: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            takenAt: (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap { formatter.date(from: $0) }
        )
    }
}
