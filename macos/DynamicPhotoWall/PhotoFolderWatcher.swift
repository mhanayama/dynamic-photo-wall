import CoreServices
import Foundation

@MainActor
final class PhotoFolderWatcher {
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private var roots: [URL] = []
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) { self.changed = changed }

    func watch(_ urls: [URL]) {
        let urls = urls.sorted { $0.path < $1.path }
        guard roots != urls else { return }
        stop()
        roots = urls
        guard !urls.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<PhotoFolderWatcher>.fromOpaque(info).takeUnretainedValue().receive()
            }
        }, &context, urls.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
           0.1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { WallLog.write("フォルダー監視を作成できません。定期再検索を継続します。"); return }
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { WallLog.write("フォルダー監視を開始できません。定期再検索を継続します。") }
    }

    /// Coalesce bursts such as a whole photo import into one rescan.
    func receive() {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.changed()
        }
    }

    func stop() {
        pending?.cancel(); pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        roots = []
    }
}
