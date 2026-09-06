import Containerization
import Foundation
import SwiftUI

struct StorageReport: Equatable, Sendable {
    let freeBytes: Int64
    let cacheBytes: Int64
    let volumeBytes: Int64
    let serviceDiskBytes: Int64
    let orphanedBytes: UInt64
    let obsoleteImages: [String]
    let obsoleteArtifacts: [String]
    let activeDigest: String?
}

enum StorageMaintenance {
    static func obsoleteReferences(all: [String], protected: Set<String>?) -> [String] {
        // No last-known-good metadata: retain every image, not an empty keep set.
        guard let protected, !protected.isEmpty else { return [] }
        return all.filter { !protected.contains($0) }.sorted()
    }

    static func allocatedBytes(at path: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: path.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let iterator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var bytes: Int64 = 0
        for case let item as URL in iterator {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        }
        return bytes
    }

    static func inspect(root: URL, activeDigest: String?) async throws -> StorageReport {
        for name in ["images", "artifacts", "services", "volumes", "volumes-journaled-v1"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw AppRuntimeError("Storage inspection refused an unexpected or linked \(name) directory.")
                }
            }
        }
        let images = root.appendingPathComponent("images", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let protected = (try? Data(contentsOf: root.appendingPathComponent("protected-images.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }.map(Set.init)
        var obsoleteImages: [String] = []
        var orphaned: UInt64 = 0
        if FileManager.default.fileExists(atPath: images.path) {
            let store = try ImageStore(path: images)
            obsoleteImages = obsoleteReferences(all: try await store.list().map(\.reference), protected: protected)
            orphaned = try await store.calculateOrphanedBlobsSize()
        }
        var obsoleteArtifacts: [String] = []
        if let activeDigest, activeDigest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
           FileManager.default.fileExists(atPath: artifacts.path) {
            let keep = activeDigest.replacingOccurrences(of: ":", with: "-")
            for entry in try FileManager.default.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let name = entry.lastPathComponent
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if name != keep, name.range(of: "^sha256-[a-f0-9]{64}$", options: .regularExpression) != nil,
                   values.isDirectory == true, values.isSymbolicLink != true { obsoleteArtifacts.append(name) }
            }
        }
        return StorageReport(
            freeBytes: try DiskSafety.available(at: root),
            cacheBytes: try allocatedBytes(at: images) + allocatedBytes(at: artifacts),
            volumeBytes: try allocatedBytes(at: root.appendingPathComponent("volumes-journaled-v1")) + allocatedBytes(at: root.appendingPathComponent("volumes")),
            serviceDiskBytes: try allocatedBytes(at: root.appendingPathComponent("services")),
            orphanedBytes: orphaned,
            obsoleteImages: obsoleteImages,
            obsoleteArtifacts: obsoleteArtifacts.sorted(), activeDigest: activeDigest
        )
    }

    static func clean(root: URL, preview: StorageReport) async throws -> String {
        let lease = try RuntimeStorageLease(root: root)
        defer { lease.release() }
        // Called only after the owned runtime is stopped. Recheck the preview
        // instead of silently broadening what the user confirmed.
        let current = try await inspect(root: root, activeDigest: preview.activeDigest)
        try Task.checkCancellation()
        guard current.obsoleteImages == preview.obsoleteImages,
              current.obsoleteArtifacts == preview.obsoleteArtifacts else {
            throw AppRuntimeError("The cache changed since the preview. Refresh Manage Storage before cleaning it.")
        }
        let images = root.appendingPathComponent("images", isDirectory: true)
        var freed: UInt64 = 0
        if FileManager.default.fileExists(atPath: images.path) {
            let store = try ImageStore(path: images)
            for reference in current.obsoleteImages {
                try Task.checkCancellation()
                try await store.delete(reference: reference, performCleanup: false)
            }
            freed = try await store.cleanUpOrphanedBlobs().freed
        }
        for name in current.obsoleteArtifacts {
            let target = root.appendingPathComponent("artifacts", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.removeItem(at: target)
        }
        return "Removed \(current.obsoleteImages.count) obsolete image references and \(current.obsoleteArtifacts.count) artifact caches; reclaimed \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file)) of image blobs. Removed caches can be downloaded again. Persistent volumes and service disks were not deleted."
    }
}

struct StorageView: View {
    @ObservedObject var model: AppModel
    @State private var confirming = false
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        Form {
            if let report = model.storageReport {
                Section("Usage") {
                    LabeledContent("Free on this disk", value: size(report.freeBytes))
                    LabeledContent("Image and artifact caches", value: size(report.cacheBytes))
                    LabeledContent("Service disks", value: size(report.serviceDiskBytes))
                    LabeledContent("Persistent data and backups", value: size(report.volumeBytes))
                }

                Section {
                    Text("\(report.obsoleteImages.count + report.obsoleteArtifacts.count) cached items can be removed.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Clean Caches and Restart…") { confirming = true }
                            .disabled(model.phase.busy || model.storageBusy)
                        Spacer()
                        if model.storageBusy {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Inspecting Studio storage")
                        }
                        Button("Refresh") { model.inspectStorage() }
                            .disabled(model.phase.busy || model.storageBusy)
                    }
                } header: {
                    Text("Cleanup")
                }
            }

            if let error = model.storageError {
                Section {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if model.storageReport == nil {
                HStack {
                    Spacer()
                    if model.storageBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Inspecting Studio storage")
                    }
                    Button("Refresh") { model.inspectStorage() }
                        .disabled(model.phase.busy || model.storageBusy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .task { model.inspectStorage() }
        .confirmationDialog("Remove the previewed caches and restart Studio’s stack?", isPresented: $confirming) {
            Button("Clean Caches and Restart", role: .destructive) { model.restart(cleanup: model.storageReport) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removed caches can be downloaded again. Persistent data will be preserved.")
        }
    }
}
