import Foundation

nonisolated enum RuntimePaths {
    static let root: URL = {
        let environment = ProcessInfo.processInfo.environment
        if environment["DPW_UI_TEST_PROFILE"] != nil || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appending(path: "DynamicPhotoWall.Tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DynamicPhotoWall", directoryHint: .isDirectory)
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

nonisolated enum WallLog {
    private static let queue = DispatchQueue(label: "DynamicPhotoWall.Log")
    static func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    static func write(_ message: String, error: Error? = nil, directory: URL = RuntimePaths.root, maximumBytes: Int = 2_000_000) {
        let entry = "\(Date().ISO8601Format()) \(message) \(error.map(String.init(describing:)) ?? "")\n"
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appending(path: "app.log")
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes {
                    let old = directory.appending(path: "app.log.1")
                    if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
                    try FileManager.default.moveItem(at: file, to: old)
                }
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } catch { /* Diagnostics must never interrupt playback. */ }
        }
    }
}

actor PhotoMetadataCache {
    static let shared = PhotoMetadataCache()
    private let file: URL
    private var values: [String: PhotoAsset]
    private var dirty = false

    init(file: URL = RuntimePaths.root.appending(path: "metadata.json")) {
        self.file = file
        values = (try? JSONDecoder().decode([String: PhotoAsset].self, from: Data(contentsOf: file))) ?? [:]
        values = values.filter { _, a in a.pixelWidth > 0 && a.pixelHeight > 0 && a.pixelWidth <= 500_000_000 / a.pixelHeight }
    }
    func find(_ url: URL, size: Int64, modified: TimeInterval) -> PhotoAsset? {
        guard let value = values[url.path], value.fileSize == size, value.modifiedAt == modified else { return nil }
        return value
    }
    func store(_ asset: PhotoAsset) { values[asset.url.path] = asset; dirty = true }
    func flush() {
        guard dirty else { return }
        do { try RuntimePaths.write(values, to: file); dirty = false }
        catch { WallLog.write("メタデータキャッシュを保存できません。", error: error) }
    }
}
