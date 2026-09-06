import Foundation
import Darwin

enum DiskSafety {
    static let reserve: Int64 = 512 * 1_024 * 1_024

    static func available(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let bytes = values.volumeAvailableCapacity else { throw AppRuntimeError("Could not determine available disk space.") }
        return Int64(bytes)
    }

    static func validate(available: Int64, additional: Int64) throws {
        guard additional >= 0, additional <= Int64.max - reserve, available >= additional + reserve else {
            throw AppRuntimeError("Not enough disk space. This operation needs \(ByteCountFormatter.string(fromByteCount: max(0, additional), countStyle: .file)) plus 512 MiB of free headroom; \(ByteCountFormatter.string(fromByteCount: max(0, available), countStyle: .file)) is available. Use Studio → Settings → Storage or free space on your Mac. Your existing volumes have not been deleted.")
        }
    }

    static func require(at directory: URL, additional: Int64) throws {
        try validate(available: available(at: directory), additional: additional)
    }

    /// Build alongside the previous disk and atomically rename only a completed
    /// replacement. On failure, remove only the staging file owned by this call.
    static func replace(at destination: URL, create: (URL) async throws -> Void) async throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).pending")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await create(staging)
        try Task.checkCancellation()
        let values = try staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AppRuntimeError("The replacement disk is not a regular file.") }
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        guard rename(staging.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        // Commit the directory entry before callers write a new identity stamp.
        guard fsync(directory) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

/// Cross-process ownership for updated Studio builds. Close releases the lease
/// automatically after a process crash; never unlink the lock file itself.
final class RuntimeStorageLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(root: URL) throws {
        let path = root.appendingPathComponent(".runtime.lock")
        descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw AppRuntimeError("Another Studio process is using this runtime. Quit the other copy before starting or cleaning this stack.")
        }
    }

    func release() { lock.withLock { if descriptor >= 0 { close(descriptor); descriptor = -1 } } }
    deinit { release() }
}
