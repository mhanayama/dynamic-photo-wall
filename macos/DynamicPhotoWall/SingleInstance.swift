import AppKit
import Darwin

@MainActor
final class SingleInstance {
    private var descriptor: Int32 = -1

    func acquire(file: URL = RuntimePaths.root.appending(path: "instance.lock")) -> Bool {
        if descriptor >= 0 { return true }
        do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { WallLog.write("単一起動ロックを作成できません。", error: error); return false }
        let fd = open(file.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { WallLog.write("単一起動ロックを開けません。errno=\(errno)"); return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }

    func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }

    func reopenExisting() {
        guard let id = Bundle.main.bundleIdentifier,
              let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else { return }
        existing.activate(options: [.activateAllWindows])
        if let url = existing.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { WallLog.write("既存の設定画面を再表示できません。", error: error) }
            }
        }
    }
}
