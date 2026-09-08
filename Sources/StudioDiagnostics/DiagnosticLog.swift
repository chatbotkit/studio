import Darwin
import Foundation
import OSLog

/// Bounded, best-effort JSON lines. Writes reach the OS synchronously, so an app
/// exit does not discard a userspace logging queue. No durability claim on power loss.
public final class DiagnosticLog: @unchecked Sendable {
    private let directory: URL
    private let maxBytes: Int
    private let archives: Int
    private let lock = NSLock()
    private var disabled = false

    public init(directory: URL, maxBytes: Int = 1_048_576, archives: Int = 3) throws {
        precondition(maxBytes >= 1024 && archives >= 0 && archives <= 10)
        self.directory = directory
        self.maxBytes = maxBytes
        self.archives = archives
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw POSIXError(.EACCES) }
    }

    public static func makeDefault() -> DiagnosticLog? {
        // Foundation resolves this inside Studio's sandbox container.
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Studio", isDirectory: true)
        do { return try DiagnosticLog(directory: directory) }
        catch {
            Logger(subsystem: "ai.cbk.studio", category: "diagnostics")
                .error("Persistent diagnostics unavailable")
            return nil
        }
    }

    public func append(source: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled else { return }
        do {
            // JSON escapes embedded newlines. Bound even an unusually large error.
            var text = String(message.prefix(16_384))
            var data: Data
            repeat {
                data = try JSONSerialization.data(withJSONObject: [
                    "time": ISO8601DateFormatter().string(from: Date()),
                    "pid": String(getpid()), "source": String(source.prefix(128)), "message": text
                ], options: [.sortedKeys])
                data.append(10)
                if data.count <= maxBytes { break }
                text = String(text.prefix(text.count / 2))
            } while true

            // Serializes separate app processes as well as this instance. Resolve
            // files relative to a verified directory; refuse symlink log targets.
            let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { throw POSIXError(.EACCES) }
            defer { close(dir) }
            let mutex = try openFile(".lock", in: dir)
            defer { close(mutex) }
            guard flock(mutex, LOCK_EX | LOCK_NB) == 0 else { return }
            defer { flock(mutex, LOCK_UN) }
            var fd = try openFile("current.jsonl", in: dir)
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
            if info.st_size + Int64(data.count) > maxBytes {
                if archives > 0 {
                    for index in stride(from: archives, through: 1, by: -1) {
                        let from = index == 1 ? "current.jsonl" : "previous-\(index - 1).jsonl"
                        let to = "previous-\(index).jsonl"
                        if renameat(dir, from, dir, to) != 0 && errno != ENOENT { throw POSIXError(.EIO) }
                    }
                    let next = try openFile("current.jsonl", in: dir)
                    close(fd)
                    fd = next
                } else if ftruncate(fd, 0) != 0 { throw POSIXError(.EIO) }
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    offset += count
                }
            }
        } catch {
            // Disk full/permission errors must not break the workspace or cause a
            // retry storm. A subsequent launch can attempt logging again.
            disabled = true
            Logger(subsystem: "ai.cbk.studio", category: "diagnostics")
                .error("Persistent diagnostics stopped after a write failure")
        }
    }

    private func openFile(_ name: String, in directory: Int32) throws -> Int32 {
        let fd = openat(directory, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid(), fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw POSIXError(.EACCES)
        }
        return fd
    }
}
