import Darwin
import Foundation

nonisolated enum PNLocalStorageError: LocalizedError {
    case previousProfile, missingIdentity, inaccessible
    var errorDescription: String? {
        switch self {
        case .previousProfile: "以前の通信データがあります。新しい通信設定の作成を選んでください。旧データはそのまま残します。"
        case .missingIdentity: "通信鍵が見つかりません。既存の通信データを守るため、新しい鍵で上書きせず停止しました。"
        case .inaccessible: "通信鍵の保存先を安全に読み書きできません。所有者・アクセス権・空き容量を確認してください。"
        }
    }
}

/// Deliberately uses filesystem protection, not Keychain. The user chose this
/// tradeoff: owner-only access does not exclude other code running as that user.
nonisolated struct PNFileSecrets: PNSecretStore {
    let directory: URL
    private static let maximumBytes = 2 * 1024 * 1024

    private func folder() throws -> Int32 {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let parent = Darwin.open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PNLocalStorageError.inaccessible }
        defer { Darwin.close(parent) }
        let name = directory.lastPathComponent
        if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST { throw PNLocalStorageError.inaccessible }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PNLocalStorageError.inaccessible }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o777 == 0o700 else { throw PNLocalStorageError.inaccessible }
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = directory; try url.setResourceValues(values)
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func validate(_ name: String) throws {
        guard ["identity-v1", "trusted-peers-v1"].contains(name) else { throw PNLocalStorageError.inaccessible }
    }
    func read(_ name: String) throws -> Data? {
        try validate(name)
        let dir = try folder(); defer { Darwin.close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw PNLocalStorageError.inaccessible }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size <= Self.maximumBytes else {
            throw PNLocalStorageError.inaccessible
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, result.count + count <= Self.maximumBytes else { throw PNLocalStorageError.inaccessible }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    func write(_ name: String, _ data: Data) throws {
        try validate(name)
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw PNLocalStorageError.inaccessible }
        let dir = try folder(); defer { Darwin.close(dir) }
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw PNLocalStorageError.inaccessible }
        defer { Darwin.close(fd); unlinkat(dir, temporary, 0) }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw PNLocalStorageError.inaccessible }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw PNLocalStorageError.inaccessible }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw PNLocalStorageError.inaccessible }
        // Never replace a device identity, including two competing first starts.
        // Trust records may be replaced atomically after an authenticated hello.
        let saved = name == "identity-v1" ? linkat(dir, temporary, dir, name, 0) : renameat(dir, temporary, dir, name)
        guard saved == 0 else { throw PNLocalStorageError.inaccessible }
        unlinkat(dir, temporary, 0)
        guard fsync(dir) == 0 else { throw PNLocalStorageError.inaccessible }
    }
}
