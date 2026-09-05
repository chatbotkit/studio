import Foundation
import Testing
@testable import Studio

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-disk-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func diskPreflightRejectsInsufficientAndOverflowingBudgets() throws {
    try DiskSafety.validate(available: DiskSafety.reserve + 10, additional: 10)
    for (available, needed): (Int64, Int64) in [(0, 0), (DiskSafety.reserve + 9, 10), (Int64.max, Int64.max), (Int64.max, -1)] {
        #expect(throws: AppRuntimeError.self) { try DiskSafety.validate(available: available, additional: needed) }
    }
}

@Test func failedReplacementPreservesOldDiskAndRemovesOnlyStaging() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let disk = root.appendingPathComponent("service.ext4")
    try Data("original".utf8).write(to: disk)
    await #expect(throws: AppRuntimeError.self) {
        try await DiskSafety.replace(at: disk) { staging in
            try Data("partial".utf8).write(to: staging)
            throw AppRuntimeError("simulated out of disk space")
        }
    }
    #expect(try Data(contentsOf: disk) == Data("original".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["service.ext4"])
}

@Test func successfulReplacementPromotesCompletedDisk() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let disk = root.appendingPathComponent("service.ext4")
    try Data("old".utf8).write(to: disk)
    try await DiskSafety.replace(at: disk) { try Data("complete".utf8).write(to: $0) }
    #expect(try Data(contentsOf: disk) == Data("complete".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["service.ext4"])
}

@Test func replacementRejectsSymlinksWithoutChangingTheirTarget() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let disk = root.appendingPathComponent("disk"), sentinel = root.appendingPathComponent("sentinel")
    try Data("protected".utf8).write(to: sentinel)
    await #expect(throws: AppRuntimeError.self) {
        try await DiskSafety.replace(at: disk) { try FileManager.default.createSymbolicLink(at: $0, withDestinationURL: sentinel) }
    }
    #expect(try Data(contentsOf: sentinel) == Data("protected".utf8))
}

@Test func cachePolicyRetainsAllImagesWithoutValidProtectionMetadata() {
    #expect(StorageMaintenance.obsoleteReferences(all: ["old", "active"], protected: nil).isEmpty)
    #expect(StorageMaintenance.obsoleteReferences(all: ["old", "active"], protected: []).isEmpty)
    #expect(StorageMaintenance.obsoleteReferences(all: ["old", "active"], protected: ["active"]) == ["old"])
}

@Test func cacheCleanupPreservesVolumesServiceDisksAndUnknownDirectories() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let active = "sha256:" + String(repeating: "a", count: 64)
    let old = "sha256-" + String(repeating: "b", count: 64)
    let preserved = ["volumes-journaled-v1", "volumes", "services", "artifacts/unknown", "artifacts/" + active.replacingOccurrences(of: ":", with: "-")]
    for path in preserved + ["artifacts/" + old] {
        let folder = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("sentinel"))
    }
    let report = try await StorageMaintenance.inspect(root: root, activeDigest: active)
    #expect(report.obsoleteArtifacts == [old])
    _ = try await StorageMaintenance.clean(root: root, preview: report)
    for path in preserved { #expect(try Data(contentsOf: root.appendingPathComponent(path + "/sentinel")) == Data("keep".utf8)) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/" + old).path))
}

@Test func changedCleanupPreviewFailsWithoutRemovingAnything() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let active = "sha256:" + String(repeating: "a", count: 64)
    let preview = try await StorageMaintenance.inspect(root: root, activeDigest: active)
    let added = root.appendingPathComponent("artifacts/sha256-" + String(repeating: "b", count: 64), isDirectory: true)
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    await #expect(throws: AppRuntimeError.self) { try await StorageMaintenance.clean(root: root, preview: preview) }
    #expect(FileManager.default.fileExists(atPath: added.path))
}

@Test func storageInspectionRejectsLinkedCacheRoots() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let outside = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("images"), withDestinationURL: outside)
    await #expect(throws: AppRuntimeError.self) { try await StorageMaintenance.inspect(root: root, activeDigest: nil) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func cancelledReplacementCannotPromoteStagedDisk() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let disk = root.appendingPathComponent("disk")
    try Data("original".utf8).write(to: disk)
    let task = Task {
        try await DiskSafety.replace(at: disk) { staging in
            try Data("replacement".utf8).write(to: staging)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: disk) == Data("original".utf8))
}

@Test func runtimeLeaseExcludesAnotherOwnerAndReleasesWithoutDeletingLockFile() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let first = try RuntimeStorageLease(root: root)
    #expect(throws: AppRuntimeError.self) { try RuntimeStorageLease(root: root) }
    first.release(); first.release()
    let second = try RuntimeStorageLease(root: root)
    second.release()
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".runtime.lock").path))
}

@Test func cleanupCannotRunWhileRuntimeOwnsStorage() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let preview = try await StorageMaintenance.inspect(root: root, activeDigest: nil)
    let lease = try RuntimeStorageLease(root: root); defer { lease.release() }
    await #expect(throws: AppRuntimeError.self) { try await StorageMaintenance.clean(root: root, preview: preview) }
}
